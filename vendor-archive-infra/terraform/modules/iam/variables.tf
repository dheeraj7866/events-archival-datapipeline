variable "name_prefix" {
  description = "Resource name prefix, e.g. vendor-archive-staging"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "sqs_queue_arn" {
  description = "ARN of the vendor-events SQS queue"
  type        = string
}

variable "sqs_dlq_arn" {
  description = "ARN of the vendor-events DLQ"
  type        = string
}

variable "ch_retry_queue_arn" {
  description = "ARN of the ClickHouse retry queue (archiver sends here on CH INSERT failure)"
  type        = string
}

variable "salt_secret_arns" {
  description = "ARNs of the vendor-logger hash-salt secrets the producer role may read"
  type        = list(string)
  default     = []
}

variable "s3_bucket_arn" {
  description = "ARN of the vendor archive S3 bucket"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the vendor-archive KMS CMK"
  type        = string
}

variable "audit_reader_principal_arns" {
  description = "IAM user/role ARNs allowed to assume the audit-reader role (MFA required)"
  type        = list(string)
  default     = []
}

variable "create_lambda_slr" {
  description = "Whether to create the Lambda service-linked role (skip if it already exists)"
  type        = bool
  default     = false
}
