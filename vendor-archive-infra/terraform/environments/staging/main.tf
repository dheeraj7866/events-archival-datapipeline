terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.55"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    bucket       = "finagle-tf-state-staging"
    key          = "vendor-archive/terraform.tfstate"
    region       = "ap-south-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-2"
  default_tags {
    tags = local.common_tags
  }
}

locals {
  env         = "staging"
  name_prefix = "vendor-archive-${local.env}"
  common_tags = {
    Project     = "vendor-archive"
    Environment = local.env
    ManagedBy   = "terraform"
    Team        = "platform"
  }
}

# ── Alerts SNS topic ──────────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = module.kms.key_id
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "slack" {
  count     = can(regex("^https://", var.slack_webhook_url)) ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source      = "../../modules/vpc"
  name_prefix = local.name_prefix
  tags        = local.common_tags

  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway

  flow_log_retention_days = var.flow_log_retention_days
}

# ── KMS ───────────────────────────────────────────────────────────────────────
module "kms" {
  source      = "../../modules/kms"
  name_prefix = local.name_prefix
  tags        = local.common_tags

  archiver_writer_role_arn    = module.iam.archiver_writer_role_arn
  audit_reader_role_arn       = module.iam.audit_reader_role_arn
  compliance_officer_role_arn = module.iam.compliance_officer_role_arn
}

# ── IAM ───────────────────────────────────────────────────────────────────────
module "iam" {
  source      = "../../modules/iam"
  name_prefix = local.name_prefix
  tags        = local.common_tags

  sqs_queue_arn      = module.sqs.queue_arn
  sqs_dlq_arn        = module.sqs.dlq_arn
  ch_retry_queue_arn = module.sqs.ch_retry_queue_arn
  s3_bucket_arn      = module.s3.bucket_arn
  kms_key_arn        = module.kms.key_arn
  salt_secret_arns = [
    aws_secretsmanager_secret.mobile_hash_salt.arn,
    aws_secretsmanager_secret.aadhaar_hash_salt.arn,
  ]

  create_scp = false
}

# ── Hash-salt secrets for @finagle/vendor-logger (read by vendor-logger-svc) ──
resource "random_password" "mobile_hash_salt" {
  length  = 64
  special = false
}
resource "random_password" "aadhaar_hash_salt" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "mobile_hash_salt" {
  name                    = "${local.name_prefix}/vendor-logger/mobile-hash-salt"
  description             = "HMAC salt for mobile hashing (@finagle/vendor-logger)"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}
resource "aws_secretsmanager_secret_version" "mobile_hash_salt" {
  secret_id     = aws_secretsmanager_secret.mobile_hash_salt.id
  secret_string = random_password.mobile_hash_salt.result
}

resource "aws_secretsmanager_secret" "aadhaar_hash_salt" {
  name                    = "${local.name_prefix}/vendor-logger/aadhaar-hash-salt"
  description             = "HMAC salt for Aadhaar last-4 hashing (@finagle/vendor-logger)"
  kms_key_id              = module.kms.key_arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}
resource "aws_secretsmanager_secret_version" "aadhaar_hash_salt" {
  secret_id     = aws_secretsmanager_secret.aadhaar_hash_salt.id
  secret_string = random_password.aadhaar_hash_salt.result
}

# ── SQS ───────────────────────────────────────────────────────────────────────
module "sqs" {
  source      = "../../modules/sqs"
  name_prefix = local.name_prefix
  tags        = local.common_tags

  kms_key_arn              = module.kms.key_arn
  archiver_writer_role_arn = module.iam.archiver_writer_role_arn
  # producer role (vendor-logger-svc) + any externally-provided service roles
  service_role_arns = concat(var.service_role_arns, [module.iam.vendor_logger_svc_role_arn])
  alert_sns_arns    = [aws_sns_topic.alerts.arn]
}

# ── S3 ────────────────────────────────────────────────────────────────────────
module "s3" {
  source      = "../../modules/s3"
  name_prefix = local.name_prefix
  tags        = local.common_tags

  bucket_name              = var.s3_bucket_name
  kms_key_arn              = module.kms.key_arn
  archiver_writer_role_arn = module.iam.archiver_writer_role_arn
}

# ── ClickHouse EC2 ────────────────────────────────────────────────────────────
module "clickhouse" {
  source      = "../../modules/clickhouse"
  name_prefix = local.name_prefix
  tags        = local.common_tags
  environment = local.env

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0]

  instance_type       = var.clickhouse_instance_type
  data_volume_size_gb = var.clickhouse_data_volume_gb
  clickhouse_version  = var.clickhouse_version

  kms_key_arn            = module.kms.key_arn
  allowed_ingress_sg_ids = [] # wired via aws_security_group_rule below to break cycle
  bastion_sg_ids         = var.bastion_sg_ids
  alert_sns_arns         = [aws_sns_topic.alerts.arn]

  # First-boot schema + credential bootstrap (single source: clickhouse/init.sql)
  init_sql = file("${path.module}/../../../clickhouse/init.sql")
}

# Break the clickhouse <-> lambda SG cycle:
# both modules create their own SG first, then we add the ingress rule here.
resource "aws_security_group_rule" "lambda_to_clickhouse_native" {
  type                     = "ingress"
  description              = "Lambda archiver to ClickHouse native port"
  from_port                = 9000
  to_port                  = 9000
  protocol                 = "tcp"
  security_group_id        = module.clickhouse.security_group_id
  source_security_group_id = module.lambda.lambda_sg_id
}

resource "aws_security_group_rule" "lambda_to_clickhouse_http" {
  type                     = "ingress"
  description              = "Lambda archiver to ClickHouse HTTP port"
  from_port                = 8123
  to_port                  = 8123
  protocol                 = "tcp"
  security_group_id        = module.clickhouse.security_group_id
  source_security_group_id = module.lambda.lambda_sg_id
}

# ── Lambda ────────────────────────────────────────────────────────────────────
module "lambda" {
  source      = "../../modules/lambda"
  name_prefix = local.name_prefix
  tags        = local.common_tags
  environment = local.env

  function_name      = "${local.name_prefix}-vendor-archiver"
  lambda_zip_path    = var.lambda_zip_path
  execution_role_arn = module.iam.archiver_writer_role_arn

  sqs_queue_arn      = module.sqs.queue_arn
  dlq_arn            = module.sqs.dlq_arn
  ch_retry_queue_url = module.sqs.ch_retry_queue_url
  kms_key_arn        = module.kms.key_arn
  s3_bucket_name     = module.s3.bucket_id

  clickhouse_host     = module.clickhouse.private_ip
  clickhouse_port     = var.clickhouse_port
  clickhouse_database = var.clickhouse_database
  clickhouse_user     = var.clickhouse_user
  clickhouse_sg_id    = module.clickhouse.security_group_id

  vpc_id               = module.vpc.vpc_id
  vpc_subnet_ids       = module.vpc.private_subnet_ids
  reserved_concurrency = var.lambda_reserved_concurrency
  alert_sns_arns       = [aws_sns_topic.alerts.arn]
}

# ── Athena cold-tier (Glue table + workgroup over the S3 archive) ─────────────
# module "athena" {
#   source      = "../../modules/athena"
#   name_prefix = local.name_prefix
#   tags        = local.common_tags
#   environment = local.env
#
#   archive_bucket = module.s3.bucket_id
#   kms_key_arn    = module.kms.key_arn
# }

# ── CloudTrail ────────────────────────────────────────────────────────────────
# module "cloudtrail" {
#   source      = "../../modules/cloudtrail"
#   name_prefix = local.name_prefix
#   tags        = local.common_tags
#
#   trail_name            = "${local.name_prefix}-trail"
#   trail_log_bucket_name = var.cloudtrail_log_bucket_name
#   kms_key_arn           = module.kms.key_arn
#   archive_bucket_arn    = module.s3.bucket_arn
#   archive_bucket_name   = module.s3.bucket_id
#
#   getobject_alarm_threshold = var.cloudtrail_getobject_threshold
#   alert_sns_arns            = [aws_sns_topic.alerts.arn]
# }

# ── CodeArtifact ──────────────────────────────────────────────────────────────
# CodeArtifact is NOT available in ap-south-2. Deploy this in ap-south-1 or
# us-east-1 separately if needed. Commented out for staging.

# module "codeartifact" {
#   source      = "../../modules/codeartifact"
#   name_prefix = local.name_prefix
#   tags        = local.common_tags
#
#   domain_name         = var.codeartifact_domain
#   repository_name     = var.codeartifact_repo
#   kms_key_arn         = module.kms.key_arn
#   publisher_role_arns = var.cicd_role_arns
#   reader_role_arns    = var.service_role_arns
# }

# ── Outputs ───────────────────────────────────────────────────────────────────
output "vpc_id" { value = module.vpc.vpc_id }
output "private_subnet_ids" { value = module.vpc.private_subnet_ids }
output "public_subnet_ids" { value = module.vpc.public_subnet_ids }
output "sqs_queue_url" { value = module.sqs.queue_url }
output "sqs_queue_arn" { value = module.sqs.queue_arn }
output "ch_retry_queue_url" { value = module.sqs.ch_retry_queue_url }
output "s3_bucket_name" { value = module.s3.bucket_id }
output "vendor_logger_svc_role_arn" { value = module.iam.vendor_logger_svc_role_arn }
output "mobile_hash_salt_secret_arn" { value = aws_secretsmanager_secret.mobile_hash_salt.arn }
output "aadhaar_hash_salt_secret_arn" { value = aws_secretsmanager_secret.aadhaar_hash_salt.arn }
output "clickhouse_private_ip" { value = module.clickhouse.private_ip }
output "clickhouse_sg_id" { value = module.clickhouse.security_group_id }
# output "codeartifact_npm_endpoint" { value = module.codeartifact.npm_endpoint }
output "compliance_officer_role_arn" { value = module.iam.compliance_officer_role_arn }
output "audit_reader_role_arn" { value = module.iam.audit_reader_role_arn }
output "kms_key_arn" { value = module.kms.key_arn }
