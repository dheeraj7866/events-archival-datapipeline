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

variable "function_name" {
  description = "Lambda function name"
  type        = string
  default     = "vendor-archiver"
}

variable "lambda_zip_path" {
  description = "Local path to the built vendor-archiver zip file"
  type        = string
}

variable "execution_role_arn" {
  description = "ARN of the archiver-writer IAM role assumed by Lambda"
  type        = string
}

variable "sqs_queue_arn" {
  description = "ARN of the vendor-events SQS queue (event source)"
  type        = string
}

variable "dlq_arn" {
  description = "ARN of the DLQ for Lambda DLQ config"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the vendor-archive CMK"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the primary S3 archive bucket"
  type        = string
}

variable "clickhouse_host" {
  description = "ClickHouse EC2 private hostname or IP"
  type        = string
}

variable "clickhouse_port" {
  description = "ClickHouse HTTP interface port — @clickhouse/client speaks HTTP (8123), NOT the native 9000"
  type        = number
  default     = 8123
}

variable "clickhouse_database" {
  description = "ClickHouse database name"
  type        = string
  default     = "vendor_archive"
}

variable "clickhouse_user" {
  description = "ClickHouse user for the archiver"
  type        = string
  default     = "archiver"
}

variable "clickhouse_secret_arn" {
  description = "Secrets Manager ARN for ClickHouse archiver password"
  type        = string
  default     = ""
}

variable "ch_retry_queue_url" {
  description = "URL of the ClickHouse retry queue (set as CH_RETRY_QUEUE_URL env var)"
  type        = string
}

variable "clickhouse_sg_id" {
  description = "Security group ID of the ClickHouse EC2 instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the Lambda security group"
  type        = string
}

variable "vpc_subnet_ids" {
  description = "Private subnet IDs the Lambda runs in"
  type        = list(string)
}

variable "reserved_concurrency" {
  description = "Lambda reserved concurrency (protects ClickHouse from overload)"
  type        = number
  default     = 10
}

variable "alert_sns_arns" {
  description = "SNS topic ARNs for CloudWatch alarm notifications"
  type        = list(string)
  default     = []
}
