# ─────────────────────────────────────────────────────────────────────────────
# Staging — ap-south-2 (Hyderabad)
# All modules active.
# Sensitive values (slack_webhook_url) — pass via:
#   export TF_VAR_slack_webhook_url="https://hooks.slack.com/..."
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC ───────────────────────────────────────────────────────────────────────
vpc_cidr                = "10.20.0.0/16"
az_count                = 2
public_subnet_cidrs     = ["10.20.0.0/24", "10.20.1.0/24"]
private_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24"]
single_nat_gateway      = true
flow_log_retention_days = 30

# ── IAM principals ────────────────────────────────────────────────────────────
# Staging does not include personal principal ARNs here.
# Replace with real role ARNs once engineering-read / platform-lead etc. are created.

# NestJS service task roles and CI role don't exist yet — empty for now.
# Add real ARNs once ECS tasks / GitHub Actions OIDC role are provisioned.
service_role_arns = []

cicd_role_arns = [
  "arn:aws:iam::761520024839:user/dheerajkumar"
]

# ── S3 ────────────────────────────────────────────────────────────────────────
s3_bucket_name = "vendor-archive-staging-aps2"

# ── ClickHouse ────────────────────────────────────────────────────────────────
clickhouse_instance_type  = "r6i.large"
clickhouse_data_volume_gb = 100
clickhouse_version        = "24.6.2.17"
clickhouse_port           = 8123 # HTTP interface — @clickhouse/client is HTTP, not native 9000
clickhouse_database       = "vendor_archive"
clickhouse_user           = "archiver"
bastion_sg_ids            = []

# ── Lambda ────────────────────────────────────────────────────────────────────
lambda_zip_path             = "../../../lambda/vendor-archiver/vendor-archiver.zip"
lambda_reserved_concurrency = 10

# ── CloudTrail ────────────────────────────────────────────────────────────────
# cloudtrail_log_bucket_name     = "vendor-archive-staging-cloudtrail-aps2"
# cloudtrail_getobject_threshold = 20
#
# ── CodeArtifact ──────────────────────────────────────────────────────────────────
# codeartifact_domain = "vendor"
# codeartifact_repo   = "vendor-logger-npm"
#
# ── Alerting ──────────────────────────────────────────────────────────────────
# Set via env var: export TF_VAR_slack_webhook_url="https://hooks.slack.com/..."
slack_webhook_url = "REPLACE_OR_SET_VIA_TF_VAR_slack_webhook_url"
