#!/bin/bash
set -euxo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# vendor-logger producer host bootstrap (prod).
# Installs Docker + compose plugin + AWS CLI v2 and prepares the deploy dir.
# App rollout itself is done by Jenkinsfile-prod (docker compose over SSH).
# ──────────────────────────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip

# --- Docker Engine + compose plugin (official Docker apt repo) ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
usermod -aG docker ubuntu

# --- AWS CLI v2 (used by Jenkinsfile-prod to fetch salts from Secrets Manager) ---
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip -q awscliv2.zip
./aws/install --update
rm -rf awscliv2.zip aws

# --- SSM agent (Ubuntu 22.04 ships it via snap; ensure it's running) ---
snap install amazon-ssm-agent --classic || true
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# --- Deploy dir Jenkins expects (docker-compose.prod.yml / .env.prod / .env.secrets) ---
mkdir -p "${deploy_dir}"
chown -R ubuntu:ubuntu "${deploy_dir}"

# --- nginx reverse proxy (only if a domain is configured) ---
# Boots HTTP-only: the proxy works immediately and nginx starts cleanly without a
# cert. Run `sudo certbot --nginx -d ${domain_name}` once to add TLS + the 80->443
# redirect (certbot rewrites this file in place; auto-renews via systemd timer).
# NOTE: no WebSocket Upgrade/Connection headers — they make plain POSTs hang (504).
%{ if domain_name != "" ~}
apt-get install -y nginx certbot python3-certbot-nginx
mkdir -p /var/www/html

cat > /etc/nginx/sites-available/${domain_name}.conf <<'NGINXEOF'
server {
    listen 80;
    listen [::]:80;
    server_name ${domain_name};

    # Let's Encrypt HTTP-01 challenge (certbot --nginx uses this dir)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    client_max_body_size 5m;
    server_tokens off;

    access_log /var/log/nginx/${domain_name}.access.log;
    error_log  /var/log/nginx/${domain_name}.error.log;

    location / {
        proxy_pass http://127.0.0.1:${app_port};
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_connect_timeout 5s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/${domain_name}.conf /etc/nginx/sites-enabled/${domain_name}.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl reload nginx
echo "nginx reverse proxy configured for ${domain_name} (HTTP-only; run certbot for TLS)"
%{ endif ~}

echo "vendor-logger host bootstrap complete (region=${region}, app_port=${app_port}, deploy_dir=${deploy_dir})"
