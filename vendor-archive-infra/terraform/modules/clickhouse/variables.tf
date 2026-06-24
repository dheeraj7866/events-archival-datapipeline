variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet ID for the ClickHouse instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type - r6i.xlarge for MVP, r6i.2xlarge for prod HA"
  type        = string
  default     = "r6i.xlarge"
}

variable "clickhouse_version" {
  description = "ClickHouse package version, e.g. 24.6.2.17"
  type        = string
  default     = "24.6.2.17"
}

variable "data_volume_size_gb" {
  description = "EBS data volume size in GB"
  type        = number
  default     = 500
}

variable "kms_key_arn" {
  description = "KMS key ARN for EBS + root volume encryption. Empty string = use AWS-managed key."
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH (use SSM Session Manager instead when possible)"
  type        = string
  default     = ""
}

variable "allowed_ingress_sg_ids" {
  description = "Security group IDs allowed to connect to ClickHouse ports (Lambda SG, Grafana SG)"
  type        = list(string)
  default     = []
}

variable "bastion_sg_ids" {
  description = "Security group IDs for bastion/jump hosts (SSH access)"
  type        = list(string)
  default     = []
}

variable "alert_sns_arns" {
  description = "SNS topic ARNs for CloudWatch alarm notifications"
  type        = list(string)
  default     = []
}

variable "init_sql" {
  description = "Contents of clickhouse/init.sql, run at first boot to create the schema + users. Empty = skip (manual bootstrap)."
  type        = string
  default     = ""
}
