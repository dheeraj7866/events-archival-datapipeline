output "bucket_id" {
  value = aws_s3_bucket.archive.id
}

output "bucket_arn" {
  value = aws_s3_bucket.archive.arn
}

output "bucket_domain_name" {
  value = aws_s3_bucket.archive.bucket_regional_domain_name
}
