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

variable "audit_reader_role_arn" {
  description = "ARN of the audit-reader role - granted Decrypt"
  type        = string
}

variable "compliance_officer_role_arn" {
  description = "ARN of the compliance-officer role - granted Decrypt"
  type        = string
}
