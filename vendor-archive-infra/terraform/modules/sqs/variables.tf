variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kms_key_arn" {
  description = "KMS key ARN for SQS message encryption at rest"
  type        = string
}

variable "archiver_writer_role_arn" {
  description = "ARN of the archiver-writer role (Lambda consumer + service sender)"
  type        = string
}

variable "service_role_arns" {
  description = "ARNs of the three NestJS service task roles that send messages"
  type        = list(string)
  default     = []
}

variable "alert_sns_arns" {
  description = "SNS topic ARNs to notify on CloudWatch alarms"
  type        = list(string)
  default     = []
}
