#!/bin/bash
set -euo pipefail
exec > /var/log/user-data.log 2>&1   # debug with: sudo cat /var/log/user-data.log

export DEBIAN_FRONTEND=noninteractive

# ── System update ─────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y ca-certificates curl unzip

# ── AWS CLI v2 (for Secrets Manager / S3 access from the box) ──────────────────
# Ubuntu's apt awscli is v1 and stale; install official v2. Idempotent.
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# ── ClickHouse install ────────────────────────────────────────────────────────
# Download to /tmp so binary path is predictable, then install as system service
cd /tmp
curl -fsSL https://clickhouse.com | sh

# Run non-interactively: skip password prompt, allow network connections
echo -e "\n\ny\n" | ./clickhouse install

# Remove auto-generated default password (no password = simpler for internal-only access)
rm -f /etc/clickhouse-server/users.d/default-password.xml

# Create systemd unit (binary installer does not create one automatically)
cat > /etc/systemd/system/clickhouse-server.service <<'UNIT'
[Unit]
Description=ClickHouse Server
After=network.target

[Service]
Type=simple
User=clickhouse
Group=clickhouse
Restart=always
RestartSec=10
LimitNOFILE=262144
LimitNPROC=131072
LimitCORE=infinity
ExecStartPre=/bin/mkdir -p /var/run/clickhouse-server
ExecStartPre=/bin/chown clickhouse:clickhouse /var/run/clickhouse-server
ExecStart=/usr/bin/clickhouse-server \
  --config-file=/etc/clickhouse-server/config.xml \
  --pid-file=/var/run/clickhouse-server/clickhouse-server.pid
WorkingDirectory=/var/lib/clickhouse
StandardOutput=journal
StandardError=journal
SyslogIdentifier=clickhouse-server

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# ── Format + mount data volume (idempotent) ───────────────────────────────────
DATA_MOUNT="${data_mount}"

# On NVMe instances (r6i, m6i, c6i...) AWS device names like /dev/xvdf appear
# inside the OS as /dev/nvme1n1. Detect the correct device name automatically.
resolve_data_device() {
  local hint="${data_device}"

  # If the hinted name exists, use it (older xen-based instances)
  test -b "$hint" && echo "$hint" && return

  # On NVMe: root is nvme0n1, first additional EBS is nvme1n1
  local nvme_candidate="/dev/nvme1n1"
  test -b "$nvme_candidate" && echo "$nvme_candidate" && return

  echo ""
}

# Wait up to 60s for the device to appear
for i in $(seq 1 12); do
  DATA_DEVICE=$(resolve_data_device)
  test -n "$DATA_DEVICE" && break
  echo "Waiting for data device ... ($i/12)"
  sleep 5
done

if [ -z "$DATA_DEVICE" ]; then
  echo "ERROR: data EBS device did not appear after 60s" >&2
  lsblk >&2
  exit 1
fi
echo "Using data device: $DATA_DEVICE"

if ! blkid "$DATA_DEVICE" > /dev/null 2>&1; then
  mkfs.ext4 -L clickhouse-data "$DATA_DEVICE"
fi

mkdir -p "$DATA_MOUNT"

if ! mountpoint -q "$DATA_MOUNT"; then
  mount "$DATA_DEVICE" "$DATA_MOUNT"
fi

if ! grep -q "LABEL=clickhouse-data" /etc/fstab; then
  echo "LABEL=clickhouse-data  $DATA_MOUNT  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

chown -R ${ch_user}:${ch_group} "$DATA_MOUNT"

# ── Listen on all interfaces ──────────────────────────────────────────────────
# Default ClickHouse binds to 127.0.0.1 only, so the Lambda (private IP) gets
# ECONNREFUSED. Bind to 0.0.0.0 — access is still gated by the security group
# (private subnet, Lambda + Grafana SGs only).
mkdir -p /etc/clickhouse-server/config.d
cat > /etc/clickhouse-server/config.d/listen.xml <<'LISTEN'
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <!-- PostgreSQL wire protocol — dev GUIs (pgAdmin, psql). SG-gated, private subnet only. -->
    <postgresql_port>9005</postgresql_port>
</clickhouse>
LISTEN

# ── Enable + start ────────────────────────────────────────────────────────────
systemctl enable clickhouse-server
systemctl start clickhouse-server

# ── Schema + credential bootstrap (idempotent, best-effort) ───────────────────
# Creates the canonical schema/users and reconciles the archiver password with
# Secrets Manager (the secret is the source of truth). Safe to re-run — all DDL is
# CREATE ... IF NOT EXISTS. Best-effort: failures here log a WARN but do NOT fail
# the boot, so the manual fallback (README §4) still works.
#
# NOTE (prod hardening): for prod, prefer Terraform owning the password
# (random_password -> secret_version) with the box only READING it. That needs the
# secret moved out of the lambda module to the env root to avoid a module cycle.

cat > /root/init.sql <<'INITSQL'
${init_sql}
INITSQL

bootstrap_clickhouse() {
  local region="${region}"
  local secret_id="${archiver_secret_id}"

  # 1) Wait for ClickHouse to accept queries (~60s max)
  local up=""
  for i in $(seq 1 30); do
    if clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then up=1; break; fi
    sleep 2
  done
  [ -n "$up" ] || { echo "ClickHouse not ready in time"; return 1; }

  # 2) Schema (idempotent)
  clickhouse-client --multiquery < /root/init.sql
  echo "schema applied from /root/init.sql"

  # 3) Wait for the archiver secret to exist (created in the same apply ~ racey)
  local have_secret=""
  for i in $(seq 1 30); do
    if aws secretsmanager describe-secret --region "$region" --secret-id "$secret_id" >/dev/null 2>&1; then
      have_secret=1; break
    fi
    sleep 5
  done
  [ -n "$have_secret" ] || { echo "secret $secret_id not found after wait — set archiver pw manually"; return 1; }

  # 4) Reconcile archiver password (secret = source of truth)
  local current
  current=$(aws secretsmanager get-secret-value --region "$region" \
    --secret-id "$secret_id" --query SecretString --output text 2>/dev/null || true)

  if [ -z "$current" ] || [ "$current" = "None" ] || [ "$current" = "CHANGE_ME_IN_SECRETS_MANAGER" ]; then
    local pw; pw=$(openssl rand -base64 24)
    clickhouse-client --query "ALTER USER archiver IDENTIFIED BY '$pw'"
    aws secretsmanager put-secret-value --region "$region" \
      --secret-id "$secret_id" --secret-string "$pw" >/dev/null
    echo "archiver password generated and written to $secret_id"
  else
    clickhouse-client --query "ALTER USER archiver IDENTIFIED BY '$current'"
    echo "archiver password synced from existing secret $secret_id"
  fi

  # 5) grafana_reader: rotate off the placeholder. Not stored in SM (datasource is
  #    configured manually); the dev password is in this log only.
  local gpw; gpw=$(openssl rand -base64 24)
  clickhouse-client --query "ALTER USER grafana_reader IDENTIFIED BY '$gpw'" \
    && echo "grafana_reader dev password (use in Grafana datasource): $gpw"
}

if ! bootstrap_clickhouse; then
  echo "WARN: clickhouse bootstrap incomplete — run clickhouse/init.sql + set passwords manually (README §4)"
fi

echo "ClickHouse user_data completed successfully at $(date)"
