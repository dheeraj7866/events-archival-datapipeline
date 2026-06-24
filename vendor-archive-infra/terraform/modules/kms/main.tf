data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ──────────────────────────────────────────────────────────────────────────────
# KMS CMK  alias/vendor-archive-cmk
# Used for: S3 SSE-KMS + Aadhaar last-4 column encryption (D2)
#
# Key policy design:
#   - Root allowed only to delegate via IAM (AWS requirement — cannot deny root)
#   - key_admin_role_arns: full key management (rotate, schedule deletion, etc.)
#   - archiver-writer: Encrypt + GenerateDataKey only (no Decrypt)
#   - audit-reader + compliance-officer: Decrypt only
#   - Deletion protection: 30-day pending window
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_kms_key" "vendor_archive" {
  description             = "Vendor archive CMK - S3 SSE + Aadhaar last-4 column encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false

  policy = data.aws_iam_policy_document.kms_key_policy.json

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vendor-archive-cmk"
  })
}

resource "aws_kms_alias" "vendor_archive" {
  name          = "alias/${var.name_prefix}-vendor-archive-cmk"
  target_key_id = aws_kms_key.vendor_archive.key_id
}

data "aws_iam_policy_document" "kms_key_policy" {
  # ── Root: enable IAM-based delegation (AWS mandatory requirement) ──
  # Root cannot be denied in KMS key policies — AWS blocks key creation.
  # Actual access control is enforced by the statements below + IAM policies.
  statement {
    sid    = "EnableIAMPolicies"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # ── key_admin_role_arns: key management (rotate, disable, schedule deletion) ──
  dynamic "statement" {
    for_each = length(var.key_admin_role_arns) > 0 ? [1] : []
    content {
      sid    = "KeyAdminAccess"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = var.key_admin_role_arns
      }
      actions = [
        "kms:Create*",
        "kms:Describe*",
        "kms:Enable*",
        "kms:List*",
        "kms:Put*",
        "kms:Update*",
        "kms:Revoke*",
        "kms:Disable*",
        "kms:Get*",
        "kms:Delete*",
        "kms:TagResource",
        "kms:UntagResource",
        "kms:ScheduleKeyDeletion",
        "kms:CancelKeyDeletion",
      ]
      resources = ["*"]
    }
  }

  # ── archiver-writer: encrypt only, no decrypt ──
  statement {
    sid    = "ArchiverWriterEncrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.archiver_writer_role_arn]
    }
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # ── audit-reader: decrypt for audit access ──
  dynamic "statement" {
    for_each = var.audit_reader_role_arn != "" ? [1] : []
    content {
      sid    = "AuditReaderDecrypt"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = [var.audit_reader_role_arn]
      }
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = ["*"]
    }
  }

  # ── compliance-officer: decrypt for Legal Hold review ──
  dynamic "statement" {
    for_each = var.compliance_officer_role_arn != "" ? [1] : []
    content {
      sid    = "ComplianceOfficerDecrypt"
      effect = "Allow"
      principals {
        type        = "AWS"
        identifiers = [var.compliance_officer_role_arn]
      }
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = ["*"]
    }
  }

  # ── S3 service: SSE-KMS operations ──
  statement {
    sid    = "S3ServiceSSE"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }

  # ── CloudTrail: log delivery encryption ──
  statement {
    sid    = "CloudTrailLogDelivery"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # ── CloudWatch Logs: log group encryption (Lambda + VPC flow + CloudTrail CW) ──
  statement {
    sid    = "CloudWatchLogsEncryption"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${local.account_id}:*"]
    }
  }
}
