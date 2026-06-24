# ── VPC ───────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of AZs to use"
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "Share one NAT GW across AZs (cost saving for staging)"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "VPC flow log retention in days"
  type        = number
  default     = 30
}

# ── IAM principals ────────────────────────────────────────────────────────────
variable "service_role_arns" {
  description = "IAM role ARNs of the three NestJS services (SQS send + CodeArtifact read)"
  type        = list(string)
  default     = []
}

variable "cicd_role_arns" {
  description = "IAM role ARNs for CI/CD pipelines (CodeArtifact publish)"
  type        = list(string)
}

# ── S3 ────────────────────────────────────────────────────────────────────────
variable "s3_bucket_name" {
  description = "Name of the vendor archive S3 bucket"
  type        = string
}

# ── ClickHouse ────────────────────────────────────────────────────────────────
variable "clickhouse_instance_type" {
  description = "EC2 instance type for ClickHouse"
  type        = string
  default     = "r6i.large"
}

variable "clickhouse_data_volume_gb" {
  description = "EBS data volume size in GB"
  type        = number
  default     = 100
}

variable "clickhouse_version" {
  description = "ClickHouse version to install"
  type        = string
  default     = "24.6.2.17"
}

variable "clickhouse_port" {
  description = "ClickHouse native protocol port"
  type        = number
  default     = 9000
}

variable "clickhouse_database" {
  description = "ClickHouse database name"
  type        = string
  default     = "vendor_archive"
}

variable "clickhouse_user" {
  description = "ClickHouse user for the archiver Lambda"
  type        = string
  default     = "archiver"
}

variable "bastion_sg_ids" {
  description = "SG IDs allowed SSH into ClickHouse (leave empty to use SSM only)"
  type        = list(string)
  default     = []
}

# ── Lambda ────────────────────────────────────────────────────────────────────
variable "lambda_zip_path" {
  description = "Local path to the built vendor-archiver.zip"
  type        = string
}

variable "lambda_reserved_concurrency" {
  description = "Lambda reserved concurrency"
  type        = number
  default     = 10
}

# ── CloudTrail ────────────────────────────────────────────────────────────────
# variable "cloudtrail_log_bucket_name" {
#   description = "S3 bucket name for CloudTrail log delivery"
#   type        = string
# }
#
# variable "cloudtrail_getobject_threshold" {
#   description = "GetObject count per 5-min window that triggers the anomaly alarm"
#   type        = number
#   default     = 20
# }
#
# ── CodeArtifact ──────────────────────────────────────────────────────────────
# variable "codeartifact_domain" {
#   description = "CodeArtifact domain name"
#   type        = string
#   default     = "vendor"
# }
#
# variable "codeartifact_repo" {
#   description = "CodeArtifact repository name"
#   type        = string
#   default     = "vendor-logger-npm"
# }
#
# ── Alerting ──────────────────────────────────────────────────────────────────
# Slack alert delivery has been removed in staging. Notifications are sent via email.
