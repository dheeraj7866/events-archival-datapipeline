variable "name_prefix" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "bucket_name" {
  description = "Archive bucket name, e.g. vendor-archive-staging-aps2"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS CMK for SSE"
  type        = string
}

variable "archiver_writer_role_arn" {
  description = "ARN of the archiver-writer role (PutObject only)"
  type        = string
}
