# ── VPC ───────────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type    = number
  default = 2
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "single_nat_gateway" {
  type    = bool
  default = false
}

variable "flow_log_retention_days" {
  type    = number
  default = 90
}

# ── IAM principals ────────────────────────────────────────────────────────────
variable "key_admin_role_arns" {
  type = list(string)
}

variable "audit_reader_principal_arns" {
  type = list(string)
}

variable "compliance_officer_principal_arns" {
  type = list(string)
}

variable "service_role_arns" {
  type    = list(string)
  default = []
}

variable "cicd_role_arns" {
  type = list(string)
}

# ── SCP ───────────────────────────────────────────────────────────────────────
variable "create_scp" {
  description = "Whether to attach the Organizations SCP guardrail for Legal Hold"
  type        = bool
  default     = true
}

variable "scp_target_id" {
  description = "AWS Organizations account/OU ID for SCP attachment"
  type        = string
  default     = ""
}

# ── S3 ────────────────────────────────────────────────────────────────────────
variable "s3_bucket_name" {
  type = string
}

# ── ClickHouse ────────────────────────────────────────────────────────────────
variable "clickhouse_instance_type" {
  type    = string
  default = "r6i.xlarge"
}

variable "clickhouse_data_volume_gb" {
  type    = number
  default = 500
}

variable "clickhouse_version" {
  type    = string
  default = "24.6.2.17"
}

variable "clickhouse_port" {
  type    = number
  default = 9000
}

variable "clickhouse_database" {
  type    = string
  default = "vendor_archive"
}

variable "clickhouse_user" {
  type    = string
  default = "archiver"
}

variable "bastion_sg_ids" {
  type    = list(string)
  default = []
}

# ── Lambda ────────────────────────────────────────────────────────────────────
variable "lambda_zip_path" {
  type = string
}

variable "lambda_reserved_concurrency" {
  type    = number
  default = 10
}

# ── CloudTrail ────────────────────────────────────────────────────────────────
variable "cloudtrail_log_bucket_name" {
  type = string
}

variable "cloudtrail_getobject_threshold" {
  type    = number
  default = 50
}

# ── CodeArtifact ──────────────────────────────────────────────────────────────
variable "codeartifact_domain" {
  type    = string
  default = "vendor"
}

variable "codeartifact_repo" {
  type    = string
  default = "vendor-logger-npm"
}

# ── Alerting ──────────────────────────────────────────────────────────────────
variable "slack_webhook_url" {
  description = "Slack incoming webhook URL for SNS alert subscription"
  type        = string
  sensitive   = true
}

# ── vendor-logger producer host (vendor_logger) ───────────────────────
variable "vendor_logger_instance_type" {
  description = "EC2 instance type for the vendor-logger producer (small by design)."
  type        = string
  default     = "t3.small"
}

variable "vendor_logger_root_volume_gb" {
  description = "Root EBS size for the vendor-logger host (OS + Docker image)."
  type        = number
  default     = 20
}

variable "vendor_logger_associate_public_ip" {
  description = "Give the vendor-logger host a public IP (true only if Jenkins reaches it over the internet; otherwise keep false + use a private subnet + SSM/bastion)."
  type        = bool
  default     = false
}

variable "vendor_logger_allocate_eip" {
  description = "Allocate a stable Elastic IP for the vendor-logger host (so the IP survives instance replacement)."
  type        = bool
  default     = false
}

variable "vendor_logger_ecr_repository_arn" {
  description = "ECR repo ARN the image is pulled from (scopes the host's pull policy)."
  type        = string
  default     = "arn:aws:ecr:ap-south-1:761520024839:repository/tezcredit/vendor_logger"
}

variable "vendor_logger_allowed_ssh_cidrs" {
  description = "CIDRs allowed SSH to the vendor-logger host (e.g. Jenkins /32). Never 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "vendor_logger_allowed_web_cidrs" {
  description = "CIDRs allowed to reach nginx 80/443 on the vendor-logger host (public HTTPS endpoint logger.tezcredit.com)."
  type        = list(string)
  default     = []
}

variable "vendor_logger_domain_name" {
  description = "Public hostname nginx fronts on the vendor-logger host. Set => user_data pre-installs nginx + reverse proxy (run certbot once for TLS). Empty => no nginx."
  type        = string
  default     = ""
}

variable "vendor_logger_key_pair_name" {
  description = "EC2 key pair name for SSH into the vendor-logger host (must match Jenkins' ec2-ssh-key private key). Empty = SSM only."
  type        = string
  default     = ""
}
