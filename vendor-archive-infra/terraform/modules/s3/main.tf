data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Single-region archive bucket - ap-south-2
#
# Key properties:
#   - SSE-KMS with dedicated CMK
#   - Lifecycle: Standard → IA (90d) → Glacier Deep Archive (1y)
#   - Versioning enabled for data integrity
#   - force_destroy enabled for test environment (full cleanup with terraform destroy)
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "archive" {
  bucket        = var.bucket_name
  force_destroy = true

  tags = merge(var.tags, {
    Name = var.bucket_name
  })
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: Standard → IA (90d) → Glacier Deep Archive (1y)
resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.archive.id

  rule {
    id     = "vendor-archive-tiering"
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
    # No expiration - indefinite retention per HLD A1
  }

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {} # apply to all objects

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.archive]
}

# Bucket policy - enforce HTTPS and KMS encryption only (test environment - deletable)
resource "aws_s3_bucket_policy" "archive" {
  bucket = aws_s3_bucket.archive.id
  policy = data.aws_iam_policy_document.bucket_policy.json

  depends_on = [aws_s3_bucket_public_access_block.archive]
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid    = "DenyNonSSL"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.archive.arn, "${aws_s3_bucket.archive.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyUnencryptedPut"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.archive.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "AllowArchiverWrite"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.archiver_writer_role_arn]
    }
    actions = [
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.archive.arn}/*"]
  }
}
