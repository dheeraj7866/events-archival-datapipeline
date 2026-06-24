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

variable "archive_bucket" {
  description = "Name (id) of the S3 archive bucket holding the meta.json sidecars"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS CMK ARN for Athena results encryption"
  type        = string
}
