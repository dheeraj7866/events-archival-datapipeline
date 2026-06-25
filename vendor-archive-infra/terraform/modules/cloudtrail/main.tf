data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# CloudTrail - data events on every GetObject/PutObject on the archive bucket
#
# Every read of a vendor archive object is audited. Per HLD §10:
# "CloudTrail data events on every GetObject. Flows to a separate audit account."
# ──────────────────────────────────────────────────────────────────────────────

# S3 bucket to store CloudTrail logs
resource "aws_s3_bucket" "trail_logs" {
  bucket        = var.trail_log_bucket_name
  force_destroy = false

  tags = merge(var.tags, { Name = var.trail_log_bucket_name })
}

resource "aws_s3_bucket_versioning" "trail_logs" {
  bucket = aws_s3_bucket.trail_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail_logs" {
  bucket = aws_s3_bucket.trail_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail_logs" {
  bucket                  = aws_s3_bucket.trail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail_logs" {
  bucket = aws_s3_bucket.trail_logs.id

  rule {
    id     = "trail-log-retention"
    status = "Enabled"

    filter {} # apply to all objects

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = 2555 # 7 years
    }
  }
}

resource "aws_s3_bucket_policy" "trail_logs" {
  bucket = aws_s3_bucket.trail_logs.id
  policy = data.aws_iam_policy_document.trail_log_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.trail_logs]
}

data "aws_iam_policy_document" "trail_log_bucket" {
  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail_logs.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${var.trail_name}"]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${var.trail_name}"]
    }
  }
}

# CloudWatch log group for real-time trail alerting
resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.name_prefix}"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}

resource "aws_iam_role" "trail_cw" {
  name               = "${var.name_prefix}-cloudtrail-cw"
  assume_role_policy = data.aws_iam_policy_document.trail_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "trail_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "trail_cw" {
  name   = "cloudtrail-cw-logs"
  role   = aws_iam_role.trail_cw.id
  policy = data.aws_iam_policy_document.trail_cw.json
}

data "aws_iam_policy_document" "trail_cw" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}

# ── The trail itself ──────────────────────────────────────────────────────────
resource "aws_cloudtrail" "vendor_archive" {
  name                          = var.trail_name
  s3_bucket_name                = aws_s3_bucket.trail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = var.kms_key_arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail_cw.arn

  # Data events - log every GetObject and PutObject on the archive bucket
  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${var.archive_bucket_arn}/"]
    }
  }

  tags = var.tags

  depends_on = [aws_s3_bucket_policy.trail_logs]
}

# ── CloudWatch metric filter + alarm: unusual GetObject rate ─────────────────
# An unexpected spike in reads may indicate PII exfiltration attempt

resource "aws_cloudwatch_log_metric_filter" "getobject_rate" {
  name           = "${var.name_prefix}-archive-getobject"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ($.eventName = \"GetObject\") && ($.requestParameters.bucketName = \"${var.archive_bucket_name}\") }"

  metric_transformation {
    name          = "ArchiveGetObjectCount"
    namespace     = "VendorArchive/CloudTrail"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "getobject_spike" {
  alarm_name          = "${var.name_prefix}-archive-getobject-spike"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ArchiveGetObjectCount"
  namespace           = "VendorArchive/CloudTrail"
  period              = 300
  statistic           = "Sum"
  threshold           = var.getobject_alarm_threshold
  treat_missing_data  = "notBreaching"

  alarm_description = "Unusual GetObject rate on vendor archive bucket - possible PII access anomaly"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}

