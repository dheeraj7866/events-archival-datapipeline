variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "key_admin_role_arns" {
  description = "IAM role ARNs allowed to manage the KMS key (NOT encrypt/decrypt)"
  type        = list(string)
  default     = []
}

variable "archiver_writer_role_arn" {
  description = "ARN of the archiver-writer role - granted Encrypt + GenerateDataKey"
  type        = string
}
