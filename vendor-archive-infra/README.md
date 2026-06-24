# Vendor Archive — Infrastructure README

**Project:** Vendor API Archive & Real-Time Failure Monitoring  
**Stack:** Tez Credit / Finagle · NestJS lending platform  
**Region:** `ap-south-2` (Hyderabad, India)  
**Terraform state:** S3 bucket `finagle-tf-state-staging` · lock via `use_lockfile`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Resources Created](#2-resources-created)
3. [How Resources Connect](#3-how-resources-connect)
4. [Credentials & Access](#4-credentials--access)
5. [Connecting to ClickHouse](#5-connecting-to-clickhouse)
6. [Troubleshooting](#6-troubleshooting)
7. [Runbooks](#7-runbooks)
8. [Open Decisions](#8-open-decisions)
9. [Vendor-Logger Producer Host (prod · ap-south-1)](#9-vendor-logger-producer-host-prod--ap-south-1)

---

## 1. Architecture Overview

```
NestJS Services (identity-api · los-api · payment-api)
         │
         │  @finagle/vendor-logger  (sync, < 1ms overhead)
         │
         ▼
  ┌─────────────┐     ┌──────────────────────────────┐
  │  SQS Queue  │────▶│  Lambda vendor-archiver       │
  │  (batch     │     │  Node.js 20 · arm64           │
  │   500/5s)   │     │  Private subnet · VPC ENI     │
  └─────────────┘     └──────────┬──────────┬─────────┘
        │                        │          │
      DLQ                        │          │
  (5 retries)                    ▼          ▼
                         ┌──────────┐  ┌────────────────────┐
                         │ClickHouse│  │  S3 Archive         │
                         │ EC2      │  │  vendor-archive-    │
                         │ r6i.large│  │  staging-aps2       │
                         │ Private  │  │  Object Lock COMPL. │
                         │ subnet   │  │  + Legal Hold ON    │
                         └──────────┘  │  SSE-KMS            │
                                       └────────────────────┘
                                              │
                                       KMS CMK (alias/
                                       vendor-archive-
                                       staging-cmk)
```

**Data flow:**
1. NestJS service makes a vendor API call via `VendorHttpService.call()`
2. Logger emits Prometheus metrics (sync) and sends event to SQS (sync, `< 1ms`)
3. Lambda consumes batches of up to 500 events every 5 seconds
4. Lambda writes raw payloads to **S3** (compliance archive, forever) and inserts metadata rows to **ClickHouse** (queryable, 90-day TTL)
5. Grafana queries ClickHouse for dashboards

---

## 2. Resources Created

### Networking — `module.vpc`

| Resource | Name / Value | Purpose |
|---|---|---|
| VPC | `vendor-archive-staging-vpc` | `10.20.0.0/16` |
| Public subnets | `-public-ap-south-2a/b` | NAT Gateway, future bastion |
| Private subnets | `-private-ap-south-2a/b` (`10.20.10.0/24`, `10.20.11.0/24`) | ClickHouse EC2, Lambda |
| Internet Gateway | `-igw` | Public subnet internet |
| NAT Gateway | `-nat-0` (single, shared) | Private subnet outbound |
| VPC Endpoint S3 | Gateway — free | Lambda → S3 without NAT |
| VPC Endpoint SQS | Interface | Lambda → SQS without NAT |
| VPC Endpoint KMS | Interface | Lambda → KMS without NAT |
| VPC Endpoint Secrets Manager | Interface | Lambda → SM without NAT |
| VPC Endpoint CloudWatch Logs | Interface | Lambda log delivery |
| VPC Endpoint SSM/SSMMessages/EC2Messages | Interface | Session Manager access to EC2 |
| VPC Flow Logs | `/aws/vpc/vendor-archive-staging-flow-logs` | Network audit |

### Encryption — `module.kms`

| Resource | Value |
|---|---|
| KMS CMK | `alias/vendor-archive-staging-vendor-archive-cmk` |
| Key rotation | Enabled (annual) |
| Deletion protection | 30-day waiting period |
| Who can encrypt | `archiver-writer` role (Lambda) |
| Who can decrypt | `audit-reader` + `compliance-officer` roles |
| Used for | S3 SSE, SQS at-rest, CloudWatch Logs, Secrets Manager, EBS |

### IAM — `module.iam`

| Role | ARN suffix | Purpose |
|---|---|---|
| `archiver-writer` | `-archiver-writer` | Lambda execution role — SQS consume, S3 write, KMS encrypt, VPC ENI |
| `audit-reader` | `-audit-reader` | Human read-only access to S3 + KMS decrypt (MFA required) |
| `compliance-officer` | `-compliance-officer` | Only role that can lift S3 Legal Hold (MFA required) |

### Queuing — `module.sqs`

| Resource | Name | Value |
|---|---|---|
| Main queue | `vendor-archive-staging-vendor-events-q` | Standard, 256 KB max, 4-day retention |
| DLQ | `vendor-archive-staging-vendor-events-dlq` | 14-day retention, fires after 5 receive attempts |
| CW Alarm | `dlq-depth` | Alerts if DLQ depth > 0 for 5 min |
| CW Alarm | `queue-age` | Alerts if oldest message > 60s |

### Archive Storage — `module.s3`

| Resource | Value |
|---|---|
| Bucket | `vendor-archive-staging-aps2` |
| Object Lock | COMPLIANCE mode, 100-year default retention |
| Legal Hold | ON for every object at write time |
| Encryption | SSE-KMS with CMK |
| Lifecycle | Standard → IA at 90d → Glacier Deep Archive at 1y |
| Versioning | Enabled (required for Object Lock) |
| Public access | Fully blocked |

### Compute — `module.clickhouse`

| Resource | Value |
|---|---|
| EC2 instance | `vendor-archive-staging-clickhouse` |
| Instance type | `r6i.large` (staging) |
| AMI | Ubuntu 22.04 LTS (Jammy) |
| Root volume | 30 GB gp3, encrypted |
| Data volume | 100 GB gp3, encrypted, mounted at `/var/lib/clickhouse` |
| EBS snapshots | Daily via DLM, 7-day retention |
| Access | AWS SSM Session Manager (no SSH key needed) |
| Security group | `vendor-archive-staging-clickhouse-sg` |
| Ports | 9000 (native), 8123 (HTTP) — private subnet only |

### Lambda — `module.lambda`

| Resource | Value |
|---|---|
| Function | `vendor-archive-staging-vendor-archiver` |
| Runtime | Node.js 20 · arm64 (Graviton) |
| Memory | 512 MB |
| Timeout | 300s (5 min) |
| Trigger | SQS — batch 500, window 5s, `ReportBatchItemFailures` |
| Concurrency | Reserved: 10 |
| Tracing | X-Ray Active |
| CH password | AWS Secrets Manager: `vendor-archive-staging/clickhouse/archiver-password` |
| Log group | `/aws/lambda/vendor-archive-staging-vendor-archiver` (30-day retention) |

### Audit — `module.cloudtrail`

| Resource | Value |
|---|---|
| Trail | `vendor-archive-staging-trail` (multi-region) |
| Scope | Data events: every `GetObject` + `PutObject` on archive bucket |
| Log bucket | `vendor-archive-staging-cloudtrail-aps2` |
| CW alarm | `legal-hold-removal` — fires immediately on any Legal Hold lift |
| CW alarm | `getobject-spike` — fires if > 20 reads in 5 min (anomaly) |

---

## 3. How Resources Connect

```
┌──────────────────────────────────────────────────────────────┐
│                    ap-south-2  VPC 10.20.0.0/16              │
│                                                              │
│  Public subnets (10.20.0.x, 10.20.1.x)                      │
│  ┌─────────────┐                                             │
│  │  NAT Gateway│ ◀── Internet Gateway ◀── 0.0.0.0/0         │
│  └──────┬──────┘                                             │
│         │ (outbound for private subnets)                     │
│  Private subnets (10.20.10.x, 10.20.11.x)                   │
│  ┌────────────────────────────────────────────────────┐      │
│  │                                                    │      │
│  │  ┌─────────────┐        ┌─────────────────────┐   │      │
│  │  │  Lambda SG  │──9000─▶│  ClickHouse SG      │   │      │
│  │  │  (archiver) │──8123─▶│  (EC2 r6i.large)    │   │      │
│  │  └──────┬──────┘        └─────────────────────┘   │      │
│  │         │                                          │      │
│  │  VPC Endpoints (S3 Gateway, SQS/KMS/SM Interface)  │      │
│  └────────────────────────────────────────────────────┘      │
└──────────────────────────────────────────────────────────────┘

AWS Service Connections (all via VPC Endpoints — no NAT traffic):
Lambda → SQS     : consume events (VPC endpoint)
Lambda → S3      : PutObject + PutObjectLegalHold (VPC endpoint)
Lambda → KMS     : Encrypt/GenerateDataKey (VPC endpoint)
Lambda → SecretsManager : GetSecretValue for CH password (VPC endpoint)
Lambda → ClickHouse     : TCP 9000 (private subnet, SG rule)
Lambda → CloudWatch Logs: PutLogEvents (VPC endpoint)

IAM chain:
Lambda execution role (archiver-writer)
  ├── SQS: ReceiveMessage, DeleteMessage, GetQueueAttributes
  ├── S3:  PutObject, PutObjectLegalHold  (on archive bucket only)
  ├── KMS: Encrypt, GenerateDataKey       (on CMK only)
  ├── SM:  GetSecretValue                 (on vendor-archive-staging/* only)
  ├── EC2: CreateNetworkInterface, Delete, Describe (VPC ENI management)
  ├── Logs: CreateLogGroup/Stream, PutLogEvents
  └── X-Ray: PutTraceSegments, PutTelemetryRecords
```

---

## 4. Credentials & Access

There are **two completely separate user systems** in this setup. Do not confuse them.

---

### System A — EC2 / Ubuntu OS users (access to the machine itself)

| User | How to connect | Who needs it |
|---|---|---|
| `ubuntu` | AWS SSM Session Manager — no password, no SSH key | Any developer needing shell access to the EC2 |
| `root` | `sudo -i` from inside ubuntu session | System administration only |
| `clickhouse` | Never log in as this — it is the OS service account that runs the ClickHouse process | Nobody |

**Connect to the EC2:**
```bash
# No password. No SSH key. Just AWS credentials + SSM.
aws ssm start-session \
  --target i-0xxxxxxxxxxxxxxxxx \
  --region ap-south-2
```

---

### System B — ClickHouse database users (access to the database)

These are users **inside ClickHouse** — like MySQL/Postgres users. They have nothing to do with the EC2 OS.

| User | Password | Used by | Permissions |
|---|---|---|---|
| `default` | **Empty string** — no password | Developers for manual queries and debug | Full superuser access |
| `archiver` | AWS Secrets Manager: `vendor-archive-staging/clickhouse/archiver-password` | **Lambda function only** — automated, never human | INSERT on `vendor_archive.vendor_api_events` only |
| `grafana_reader` | You set manually after init | **Grafana** datasource | SELECT on `vendor_archive.*` only |

**Developer connecting to ClickHouse for queries:**
```bash
# Step 1 — get onto EC2 via SSM (no password)
aws ssm start-session --target i-0xxxxxxxxx --region ap-south-2

# Step 2 — connect to ClickHouse as default user (press Enter for empty password)
clickhouse-client
# :) prompt appears — now run any SQL
```

**Lambda → ClickHouse (automated, no human involved):**
- Lambda uses the `archiver` user
- Password lives in Secrets Manager — Lambda reads it automatically at cold start
- Developers never need to know or type this password

**Grafana → ClickHouse:**
- Uses `grafana_reader` user
- Configure in Grafana datasource: host = ClickHouse private IP, port = `8123`, user = `grafana_reader`

---

### One-time setup after first `terraform apply`

```bash
# 1. SSM onto the EC2
aws ssm start-session --target i-0xxxxxxxxx --region ap-south-2

# 2. Connect as default (no password — just press Enter)
clickhouse-client

# 3. Load the schema (creates DB, table, users)
# Exit clickhouse-client first, then:
clickhouse-client < /home/ubuntu/init.sql

# 4. Generate a strong archiver password and store it in both places
PASSWORD=$(openssl rand -base64 32)

# Store in Secrets Manager (Lambda reads from here)
aws secretsmanager put-secret-value \
  --secret-id "vendor-archive-staging/clickhouse/archiver-password" \
  --secret-string "$PASSWORD" \
  --region ap-south-2

# Set the same password in ClickHouse
clickhouse-client --query "ALTER USER archiver IDENTIFIED BY '$PASSWORD'"

# 5. Set a grafana_reader password (your choice)
clickhouse-client --query "ALTER USER grafana_reader IDENTIFIED BY 'your-grafana-password'"
```

### AWS IAM Roles

| Role | How to assume | Use case |
|---|---|---|
| `archiver-writer` | Assumed automatically by Lambda | Do not use directly |
| `audit-reader` | `aws sts assume-role --role-arn <arn> --role-session-name audit` (MFA required) | Read S3 archive objects |
| `compliance-officer` | `aws sts assume-role` with MFA | Lift Legal Hold (emergency only) |

### Terraform State

- **Bucket:** `finagle-tf-state-staging` (ap-south-2)  
- **Key:** `vendor-archive/terraform.tfstate`  
- **Lock:** S3 native lockfile (`use_lockfile = true`)  
- Access: whoever can write to the state bucket

---

## 5. Connecting to ClickHouse

ClickHouse is in a **private subnet** with no public IP. Use AWS SSM Session Manager:

### Option A — Interactive shell via SSM (recommended)

```bash
# 1. Get the instance ID
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=vendor-archive-staging-clickhouse" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text \
  --region ap-south-2

# 2. Start SSM session
aws ssm start-session \
  --target i-0xxxxxxxxxxxxxxxxx \
  --region ap-south-2

# 3. Inside the session — connect to ClickHouse
clickhouse-client                          # default user, no password
clickhouse-client --user archiver --password   # archiver user
```

### Option B — Port-forward via SSM (for local GUI tools)

```bash
# Forward local port 9000 → ClickHouse 9000 via SSM
aws ssm start-session \
  --target i-0xxxxxxxxxxxxxxxxx \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9000"],"localPortNumber":["9000"]}' \
  --region ap-south-2

# Now connect locally (DBeaver, clickhouse-client, etc.)
clickhouse-client --host 127.0.0.1 --port 9000
```

### Option C — DBeaver (recommended GUI for developers)

DBeaver has a native ClickHouse driver and connects over the **HTTP interface (port 8123)**.
ClickHouse is in a private subnet, so tunnel to it with SSM first, then point DBeaver at the local port.
Use the read-only **`grafana_reader`** user (never `default` or `archiver`).

**1. Open an SSM port-forward to 8123** (keep this terminal open — it's the tunnel):
```bash
INSTANCE_ID=$(aws ec2 describe-instances --region ap-south-2 \
  --filters "Name=tag:Name,Values=vendor-archive-staging-clickhouse" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ssm start-session --target "$INSTANCE_ID" --region ap-south-2 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8123"],"localPortNumber":["8123"]}'
```
(Requires the AWS CLI + the `session-manager-plugin` installed locally.)

**2. Create the connection in DBeaver:**
- **Database → New Database Connection → ClickHouse** (DBeaver will offer to download the driver — accept).
- **Host:** `127.0.0.1`  ·  **Port:** `8123`
- **Database/schema:** `vendor_archive`
- **Username:** `grafana_reader`  ·  **Password:** (from your team password manager — not in this repo)
- Driver properties: `ssl = false` (the traffic is plaintext over the SSM-encrypted tunnel; do **not** expose 8123 publicly).
- **Test Connection** → Finish.

**3. Use it:** browse `vendor_archive` → `vendor_api_events` and run SQL in the Query Editor.
`grafana_reader` is **SELECT-only**, so any write/DDL will be denied by design — that's expected for dev access.

> The `grafana_reader` password is **not** stored in this repo or Secrets Manager. Get it from your team
> vault, or (re)set it on the box: `clickhouse-client --query "ALTER USER grafana_reader IDENTIFIED BY '…'"`.

### Option D — pgAdmin (via ClickHouse's PostgreSQL wire port 9005)

ClickHouse isn't Postgres, but it exposes a **PostgreSQL-compatible port (9005)** that pgAdmin can connect to.
SQL queries work; pgAdmin's Postgres-specific schema-tree browsing may show errors (ClickHouse only partially
emulates `pg_catalog`) — use the **Query Tool** for that. If you hit those limits, prefer DBeaver (Option C).

**1. Ensure port 9005 is enabled.** New instances enable it via `user_data`. To enable on an existing box:
```bash
# on the CH box (SSM)
mkdir -p /etc/clickhouse-server/config.d
cat > /etc/clickhouse-server/config.d/postgres.xml <<'EOF'
<clickhouse><postgresql_port>9005</postgresql_port></clickhouse>
EOF
systemctl restart clickhouse-server
ss -tlnp | grep 9005     # expect 0.0.0.0:9005 listening
```

**2. SSM port-forward to 9005** (keep the terminal open):
```bash
INSTANCE_ID=$(aws ec2 describe-instances --region ap-south-2 \
  --filters "Name=tag:Name,Values=vendor-archive-staging-clickhouse" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ssm start-session --target "$INSTANCE_ID" --region ap-south-2 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9005"],"localPortNumber":["9005"]}'
```

**3. Register the server in pgAdmin** (Object → Register → Server):
- **General → Name:** `vendor-archive (clickhouse)`
- **Connection → Host:** `127.0.0.1`  ·  **Port:** `9005`
- **Maintenance database:** `vendor_archive`
- **Username:** `grafana_reader`  ·  **Password:** (from your team password manager — not in this repo)
- Save. Open the **Query Tool** and run SQL.

`grafana_reader` is SELECT-only — writes are denied by design. If pgAdmin errors while expanding the tree or on
a server-version check, that's the ClickHouse↔Postgres protocol gap, not a credentials issue — switch to the
Query Tool or use DBeaver.

### Quick health checks

```sql
SELECT version();
SELECT hostname(), uptime();
SHOW DATABASES;
SHOW TABLES FROM vendor_archive;
SELECT count() FROM vendor_archive.vendor_api_events;

-- Last 10 ingested events
SELECT request_id, vendor_id, endpoint, status, latency_ms, created_at
FROM vendor_archive.vendor_api_events
ORDER BY created_at DESC LIMIT 10;

-- Failure rate by vendor (last 1 hour)
SELECT vendor_id, status, count() AS n
FROM vendor_archive.vendor_api_events
WHERE created_at >= now() - INTERVAL 1 HOUR
GROUP BY vendor_id, status
ORDER BY vendor_id, n DESC;
```

### Initialize schema (first time only)

```bash
# Copy init.sql to the EC2 (from your machine)
scp clickhouse/init.sql ubuntu@<private-ip>:/home/ubuntu/init.sql
# or paste contents directly in SSM session

# Run it
clickhouse-client < /home/ubuntu/init.sql
```

---

## 6. Troubleshooting

### ClickHouse won't start

```bash
# Check service status
sudo systemctl status clickhouse-server

# Check logs
sudo tail -100 /var/log/clickhouse-server/clickhouse-server.err.log
sudo journalctl -u clickhouse-server -n 100

# Check data volume is mounted
df -h | grep clickhouse
mount | grep clickhouse

# Restart
sudo systemctl restart clickhouse-server
```

### Lambda not processing events / SQS depth growing

```bash
# Check Lambda errors in CloudWatch
aws logs filter-log-events \
  --log-group-name "/aws/lambda/vendor-archive-staging-vendor-archiver" \
  --filter-pattern "ERROR" \
  --region ap-south-2 \
  --start-time $(date -v-1H +%s000)    # last 1 hour (macOS)

# Check DLQ depth
aws sqs get-queue-attributes \
  --queue-url https://sqs.ap-south-2.amazonaws.com/761520024839/vendor-archive-staging-vendor-events-dlq \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-south-2

# Replay DLQ messages back to main queue (after fixing the root cause)
aws sqs change-message-visibility-batch ...
```

### Lambda cannot connect to ClickHouse

1. Check the SG rule exists: `aws_security_group_rule.lambda_to_clickhouse_native` (port 9000)
2. Check ClickHouse is running: `sudo systemctl status clickhouse-server`
3. Check Lambda is in the right subnet (private, same VPC)
4. Check ClickHouse config allows network connections:
   ```bash
   cat /etc/clickhouse-server/config.d/listen.xml
   # Should contain: <listen_host>0.0.0.0</listen_host>
   ```

### Lambda cannot read Secrets Manager (ClickHouse password)

```bash
# Verify the secret exists
aws secretsmanager describe-secret \
  --secret-id "vendor-archive-staging/clickhouse/archiver-password" \
  --region ap-south-2

# Verify the Lambda env var has the right ARN
aws lambda get-function-configuration \
  --function-name vendor-archive-staging-vendor-archiver \
  --region ap-south-2 \
  --query "Environment.Variables.CLICKHOUSE_SECRET_ARN"
```

### S3 PutObject failing (from Lambda)

Common causes:
- KMS key policy not granting `kms:GenerateDataKey` to the archiver-writer role
- Bucket policy `DenyPutWithoutLegalHold` blocking writes that don't set Legal Hold
- Verify the Lambda is calling `PutObjectLegalHold` immediately after `PutObject`

```bash
# Check CloudTrail for S3 errors
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=PutObject \
  --region ap-south-2 \
  --max-results 10
```

### Terraform apply fails — resource already exists

```bash
# Import the existing resource into state
terraform import module.vpc.aws_cloudwatch_log_group.flow_logs \
  /aws/vpc/vendor-archive-staging-flow-logs

# General pattern
terraform import <resource_address> <resource_id>
```

### Terraform plan — provider authentication

```bash
# Verify you're in the right account and region
aws sts get-caller-identity
aws configure get region   # should be ap-south-2
```

---

## 7. Runbooks

### Deploy / re-deploy

```bash
cd terraform/environments/staging

# Build Lambda zip first (required before apply)
cd ../../../lambda/vendor-archiver
npm install && npm run build && npm run bundle
cd ../../terraform/environments/staging

# Plan and review
terraform plan -var-file="terraform.tfvars" -out=staging.tfplan

# Apply
terraform apply staging.tfplan

# Check outputs
terraform output
```

### Rotate ClickHouse archiver password

```bash
# 1. Generate new password
NEW_PASS=$(openssl rand -base64 32)

# 2. Update in ClickHouse (via SSM session)
clickhouse-client --query "ALTER USER archiver IDENTIFIED BY '$NEW_PASS'"

# 3. Update in Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id "vendor-archive-staging/clickhouse/archiver-password" \
  --secret-string "$NEW_PASS" \
  --region ap-south-2

# 4. Redeploy Lambda to pick up new secret (or wait — it re-reads on cold start)
aws lambda update-function-configuration \
  --function-name vendor-archive-staging-vendor-archiver \
  --region ap-south-2 \
  --description "force cold start for secret rotation $(date)"
```

### Emergency: disable archiving for a specific vendor

```bash
# Per-vendor kill switch via Lambda environment variable
aws lambda update-function-configuration \
  --function-name vendor-archive-staging-vendor-archiver \
  --environment "Variables={DISABLE_VENDOR_easebuzz=true}" \
  --region ap-south-2
```

### Lift S3 Legal Hold (compliance officer only)

```bash
# Requires compliance-officer IAM role (MFA) — only for court orders / legal process
aws sts assume-role \
  --role-arn arn:aws:iam::761520024839:role/vendor-archive-staging-compliance-officer \
  --role-session-name legal-hold-lift-$(date +%Y%m%d) \
  --serial-number arn:aws:iam::761520024839:mfa/device \
  --token-code <MFA_CODE>

# Then lift hold on specific object
aws s3api put-object-legal-hold \
  --bucket vendor-archive-staging-aps2 \
  --key <object-key> \
  --legal-hold '{"Status": "OFF"}'
```

---

## 8. Open Decisions

These must be closed before production cutover:

| ID | Decision | Owner | Blocks |
|---|---|---|---|
| D1 | Loan lifecycle stage enum (`LEAD/KYC/UNDERWRITING/...`) | Product | MVP merge |
| D2 | Aadhaar last-4 storage pattern (hash + KMS-encrypted) | Product + Compliance | Prod deploy |
| D3 | Easebuzz webhook capture in scope? | Product | Phase 1.5 |
| D4 | Written compliance counsel sign-off on indefinite S3 retention | Compliance counsel | Prod deploy |
| D5 | `consent_records` table — Souvik owns delivery | Souvik + Product | Phase 1.5 |
| D6 | Consent text canonical version | Product + Compliance | P1.5 |
| D7 | `compliance-officer` IAM role members (dual-control) | CTO + Compliance | Prod infra |
| D8 | Production go-live gate criteria | Engineering + Product | Prod cutover |

---

## 9. Vendor-Logger Producer Host (prod · ap-south-1)

The **producer** side (`@finagle/vendor-logger`, the NestJS service that captures vendor
API events and `SendMessage`s them to SQS) runs on a small dedicated EC2 in **prod**,
managed by `module.vendor_logger`. It is the public entry point for `/log`.

| Item | Value |
|---|---|
| Module | `terraform/modules/vendor-logger` (wired in `environments/prod/main.tf`) |
| Instance | `t3.small`, Ubuntu 22.04, 20 GB gp3 root, **public subnet** |
| Stable IP | **Elastic IP `13.207.231.147`** (survives instance replacement) |
| Public hostname | **`logger.tezcredit.com`** → A record → the EIP |
| App | Docker container, `9013 → 3013`, deployed by `finagle_vendor_logger/Jenkinsfile-prod` |
| IAM | reuses `vendor-logger-svc` role: SQS send + KMS + salt-secret read + ECR pull + SSM |
| Secrets at deploy | salts pulled from Secrets Manager **on the host**; SQS URL from a Jenkins credential |

### Security group ingress

| Port | Source | Purpose |
|---|---|---|
| 80 | `0.0.0.0/0` | nginx — Let's Encrypt ACME + redirect to 443 |
| 443 | `0.0.0.0/0` | nginx — public HTTPS (`logger.tezcredit.com`) |
| 22 | Jenkins `/32` only | deploy SSH |
| 9013 | VPC CIDR `10.30.0.0/16` only | app port — **never public**; nginx reaches it via `127.0.0.1` |

### nginx reverse proxy + TLS

`logger.tezcredit.com` is fronted by **nginx**, which terminates TLS and proxies to the
local container on `127.0.0.1:9013`. The app itself is plain HTTP and is never exposed
directly. The proxy config lives in `finagle_vendor_logger/deploy/nginx/logger.tezcredit.com.conf`
and is **pre-provisioned by the module's `user_data`** (HTTP-only at boot, so nginx starts
without a cert), gated on `vendor_logger_domain_name`.

After a fresh instance comes up (or a replacement), do the one-time TLS step:

```bash
# DNS already resolves (EIP is stable). Port 80 is open for the ACME challenge.
sudo certbot --nginx -d logger.tezcredit.com
# certbot rewrites the nginx config to add TLS + the 80->443 redirect, and auto-renews.
sudo nginx -t && sudo systemctl reload nginx
```

> Two gotchas that bite here (both designed out of the committed config — keep them out):
> - **Proxy to `127.0.0.1:9013`, never the EIP.** Proxying to the public IP hairpins into
>   the SG (9013 is VPC-only) and hangs → `504`.
> - **No WebSocket `Upgrade`/`Connection: upgrade` headers.** On a plain POST they make the
>   Node server wait for a handshake that never comes → hang → `504`.
> - Ubuntu 22.04 ships nginx 1.18 → use `listen 443 ssl http2;`, not the newer `http2 on;`.

Smoke test:
```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://logger.tezcredit.com/log \
  -H "Content-Type: application/json" -d '{"correlationId":"smoke","vendorId":"karza","endpoint":"/x","loanLifecycleStage":"KYC","status":"SUCCESS","httpStatus":200,"latencyMs":1}'
# expect 202 (fire-and-forget into the ring buffer)
```

### Calling `/log` from services in other VPCs / private subnets

Your producer services live in **other VPCs, in private subnets**. How they reach `/log`
depends entirely on whether you go over the public hostname or stay private:

**Option 1 — public hostname `https://logger.tezcredit.com/log` (works today, no infra change).**
A private-subnet service can reach a public IP *only if its subnet has outbound internet*
(a NAT gateway). If it does: the request egresses via that VPC's NAT to the internet, hits
the EIP on `443` (open to `0.0.0.0/0`), nginx proxies to the app. TLS protects it in transit.
This needs **nothing** on the vendor-logger side. If a service's subnet has **no NAT / no
internet egress**, this path will not work — use Option 2.

**Option 2 — fully private (no public internet).** Connect the VPCs and skip the internet:
- **VPC peering or Transit Gateway** between each consumer VPC and the vendor-logger VPC
  (`10.30.0.0/16`). Requires **non-overlapping CIDRs**. Then add each consumer VPC's CIDR to
  the SG (port `9013` for plain HTTP via the private IP, or `443` if you still want nginx/TLS),
  and POST to the host's **private IP** (or an internal Route 53 record).
- **AWS PrivateLink** (NLB in the vendor-logger VPC + endpoint service + interface endpoints
  in each consumer VPC) — cleanest cross-VPC private access, **works even with overlapping
  CIDRs**, no peering/route management. Best fit if the consumer VPCs are owned by different
  teams/accounts.

**Recommendation:** for internal service-to-service traffic, prefer Option 2 (private) so vendor
event payloads never traverse the public internet. If you stay on Option 1, tighten the `443`
ingress from `0.0.0.0/0` down to the **NAT egress IPs** of the consumer VPCs (leave `80` open
only for ACME, or switch certbot to DNS-01 and close `80` too).

---

## File Structure

```
vendor-archive/
├── terraform/
│   ├── modules/
│   │   ├── vpc/          VPC, subnets, NAT, VPC endpoints, flow logs
│   │   ├── kms/          CMK, key policy, alias
│   │   ├── iam/          archiver-writer, audit-reader, compliance-officer roles
│   │   ├── sqs/          vendor-events-q, DLQ, CloudWatch alarms
│   │   ├── s3/           archive bucket, Object Lock, lifecycle, bucket policy
│   │   ├── clickhouse/   EC2, EBS, SG, DLM snapshots, systemd unit
│   │   ├── lambda/       function, SQS trigger, SG, Secrets Manager, CW alarms
│   │   ├── cloudtrail/   trail, S3 logs bucket, CW metric filters + alarms
│   │   ├── vendor-logger/ producer EC2 (prod): t3.small, EIP, nginx via user_data
│   │   └── codeartifact/ (commented out — not available in ap-south-2)
│   └── environments/
│       ├── staging/      main.tf · variables.tf · terraform.tfvars
│       └── prod/         main.tf · variables.tf · terraform.tfvars
├── lambda/
│   └── vendor-archiver/
│       ├── src/index.ts  SQS handler → ClickHouse INSERT + S3 PutObject
│       ├── package.json
│       └── tsconfig.json
├── clickhouse/
│   └── init.sql          Schema: vendor_api_events table, materialized view, users
└── grafana/
    ├── dashboards/       vendor-failure-rate, vendor-latency, vendor-spend (JSON)
    └── alertmanager/     rules.yaml — P1/P2/P3 alert rules
```
