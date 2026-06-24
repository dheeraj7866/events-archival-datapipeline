variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "domain_name" {
  description = "CodeArtifact domain name"
  type        = string
  default     = "finagle"
}

variable "repository_name" {
  description = "CodeArtifact repository name for @finagle/vendor-logger"
  type        = string
  default     = "vendor-logger-npm"
}

variable "kms_key_arn" {
  description = "KMS key ARN for CodeArtifact domain encryption"
  type        = string
}

variable "publisher_role_arns" {
  description = "IAM role ARNs allowed to publish packages (CI/CD pipelines)"
  type        = list(string)
  default     = []
}

variable "reader_role_arns" {
  description = "IAM role ARNs allowed to install packages (service build roles)"
  type        = list(string)
  default     = []
}
