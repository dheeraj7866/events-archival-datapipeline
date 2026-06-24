output "key_id" {
  value = aws_kms_key.vendor_archive.key_id
}

output "key_arn" {
  value = aws_kms_key.vendor_archive.arn
}

output "alias_arn" {
  value = aws_kms_alias.vendor_archive.arn
}

output "alias_name" {
  value = aws_kms_alias.vendor_archive.name
}
