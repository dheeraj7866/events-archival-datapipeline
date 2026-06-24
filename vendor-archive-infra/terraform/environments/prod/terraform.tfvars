# ─────────────────────────────────────────────────────────────────────────────
# Production — ap-south-1 (Mumbai)
# NEVER commit real ARNs, secret values, or webhook URLs to git.
# Sensitive vars (slack_webhook_url) must be injected via TF_VAR_ env vars.
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC ───────────────────────────────────────────────────────────────────────
vpc_cidr                = "10.30.0.0/16"
az_count                = 2
public_subnet_cidrs     = ["10.30.0.0/24", "10.30.1.0/24"]
private_subnet_cidrs    = ["10.30.10.0/24", "10.30.11.0/24"]
single_nat_gateway      = true # single shared NAT (parity with staging)
flow_log_retention_days = 90

# ── IAM principals ────────────────────────────────────────────────────────────
# Parity with staging for now: all point at the deploying IAM user.
# Replace with real prod role ARNs (cto/compliance-lead, engineering-read, etc.)
# before a real production cutover.
compliance_officer_principal_arns = [
  "arn:aws:iam::761520024839:user/dheerajkumar"
]

audit_reader_principal_arns = [
  "arn:aws:iam::761520024839:user/dheerajkumar"
]

key_admin_role_arns = [
  "arn:aws:iam::761520024839:user/dheerajkumar"
]

# NestJS service task roles don't exist yet — empty (vendor-logger-svc is wired in
# automatically by main.tf via module.iam.vendor_logger_svc_role_arn).
service_role_arns = []

cicd_role_arns = [
  "arn:aws:iam::761520024839:user/dheerajkumar"
]

# ── SCP ───────────────────────────────────────────────────────────────────────
# Disabled (parity with staging — SCP needs AWS Organizations).
create_scp    = false
scp_target_id = ""

# ── S3 ────────────────────────────────────────────────────────────────────────
s3_bucket_name = "vendor-archive-prod-aps1"

# ── ClickHouse ────────────────────────────────────────────────────────────────
clickhouse_instance_type  = "r6i.xlarge"
clickhouse_data_volume_gb = 200
clickhouse_version        = "24.6.2.17"
clickhouse_port           = 8123 # HTTP interface — @clickhouse/client is HTTP, not native 9000
clickhouse_database       = "vendor_archive"
clickhouse_user           = "archiver"
bastion_sg_ids            = []

# ── vendor-logger producer host ───────────────────────────────────────────────
vendor_logger_instance_type       = "t3.small"
vendor_logger_root_volume_gb      = 20
vendor_logger_associate_public_ip = true                       # public subnet so Jenkins can SSH over the internet
vendor_logger_allocate_eip        = true                       # stable Elastic IP (survives instance replacement)
vendor_logger_allowed_ssh_cidrs   = ["40.192.17.235/32"]       # Jenkins host (SSH only)
vendor_logger_allowed_web_cidrs   = ["0.0.0.0/0"]              # public 80/443 (nginx -> logger.tezcredit.com; 80 required for Let's Encrypt)
vendor_logger_domain_name         = "logger.tezcredit.com"     # user_data pre-installs nginx reverse proxy (run certbot once for TLS)
vendor_logger_key_pair_name       = "dev-test-dheeraj" # matches Jenkins' ec2-ssh-key (imported into ap-south-1)

# ── Lambda ────────────────────────────────────────────────────────────────────
lambda_zip_path             = "../../../lambda/vendor-archiver/vendor-archiver.zip"
lambda_reserved_concurrency = 10

# ── CloudTrail ────────────────────────────────────────────────────────────────
cloudtrail_log_bucket_name     = "vendor-archive-prod-cloudtrail-aps1"
cloudtrail_getobject_threshold = 50

# ── CodeArtifact ──────────────────────────────────────────────────────────────
codeartifact_domain = "vendor"
codeartifact_repo   = "vendor-logger-npm"

# ── Alerting ──────────────────────────────────────────────────────────────────
# Set via env var: export TF_VAR_slack_webhook_url="https://hooks.slack.com/..."
slack_webhook_url = "REPLACE_OR_SET_VIA_TF_VAR_slack_webhook_url"
