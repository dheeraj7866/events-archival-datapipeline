variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "trail_name" {
  type    = string
  default = "vendor-archive-trail"
}

variable "trail_log_bucket_name" {
  description = "S3 bucket name for CloudTrail log delivery"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for trail log encryption + CW log group"
  type        = string
}

variable "archive_bucket_arn" {
  description = "ARN of the vendor archive S3 bucket (data events target)"
  type        = string
}

variable "archive_bucket_name" {
  description = "Name of the vendor archive S3 bucket (used in filter pattern)"
  type        = string
}

variable "getobject_alarm_threshold" {
  description = "GetObject count per 5-min window that triggers the anomaly alarm"
  type        = number
  default     = 50
}

variable "alert_sns_arns" {
  description = "SNS topic ARNs for alarm notifications"
  type        = list(string)
  default     = []
}
