output "archiver_writer_role_arn" {
  description = "ARN of the archiver-writer IAM role (used by Lambda)"
  value       = aws_iam_role.archiver_writer.arn
}

output "archiver_writer_role_name" {
  description = "Name of the archiver-writer IAM role"
  value       = aws_iam_role.archiver_writer.name
}

output "audit_reader_role_arn" {
  description = "ARN of the audit-reader IAM role"
  value       = length(aws_iam_role.audit_reader) > 0 ? aws_iam_role.audit_reader[0].arn : ""
}


output "vendor_logger_svc_role_arn" {
  description = "ARN of the vendor-logger-svc role (producer: SQS send + hash salts + KMS)"
  value       = aws_iam_role.vendor_logger_svc.arn
}

output "vendor_logger_svc_role_name" {
  description = "Name of the vendor-logger-svc role (for the vendor-logger EC2 instance profile)"
  value       = aws_iam_role.vendor_logger_svc.name
}
