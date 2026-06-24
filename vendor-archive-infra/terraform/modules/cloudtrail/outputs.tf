output "trail_arn" { value = aws_cloudtrail.vendor_archive.arn }
output "trail_log_bucket_id" { value = aws_s3_bucket.trail_logs.id }
output "trail_log_group_name" { value = aws_cloudwatch_log_group.trail.name }
