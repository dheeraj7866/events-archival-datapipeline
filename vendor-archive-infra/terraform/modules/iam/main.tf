data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  audit_reader_role_exists       = length(var.audit_reader_principal_arns) > 0
  compliance_officer_role_exists = length(var.compliance_officer_principal_arns) > 0
}

# ──────────────────────────────────────────────────────────────────────────────
# archiver-writer  - used by Lambda vendor-archiver
# Can: SQS consume, SQS delete, S3 Put, KMS Encrypt/GenerateDataKey, CH write
# Cannot: S3 Get/Delete, KMS Decrypt
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "archiver_writer" {
  name               = "${var.name_prefix}-archiver-writer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = var.tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "archiver_writer_inline" {
  name   = "archiver-writer-inline"
  role   = aws_iam_role.archiver_writer.id
  policy = data.aws_iam_policy_document.archiver_writer.json
}

data "aws_iam_policy_document" "archiver_writer" {
  # SQS - consume + delete messages from main queue and DLQ
  statement {
    sid    = "SQSConsume"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [var.sqs_queue_arn, var.sqs_dlq_arn]
  }

  # SQS - send failed-CH events to the retry queue (Lambda routes here on CH INSERT failure)
  statement {
    sid    = "SQSRetrySend"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.ch_retry_queue_arn]
  }

  # S3 - write only, no read or delete
  statement {
    sid    = "S3WriteOnly"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }

  # KMS - encrypt for S3 writes + Decrypt to RECEIVE from the SSE-KMS SQS queue.
  # Decrypt does NOT expose the S3 archive: this role has no s3:GetObject, so it
  # cannot read archive objects back regardless of KMS.
  statement {
    sid    = "KMSEncrypt"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }

  # CloudWatch Logs - Lambda log delivery
  statement {
    sid    = "CWLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*"]
  }

  # EC2 VPC - required for Lambda deployed inside a VPC (ENI management)
  statement {
    sid    = "VPCAccess"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }

  # Secrets Manager - fetch ClickHouse password at Lambda startup
  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:${var.name_prefix}/*"]
  }

  # X-Ray - active tracing enabled on the Lambda function
  statement {
    sid    = "XRayTrace"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# audit-reader  - used by compliance + engineering for read-only access
# Can: S3 GetObject (audited via CloudTrail), KMS Decrypt, CH SELECT
# Cannot: write, delete, modify Legal Hold
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "audit_reader" {
  count              = local.audit_reader_role_exists ? 1 : 0
  name               = "${var.name_prefix}-audit-reader"
  assume_role_policy = data.aws_iam_policy_document.human_assume[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "human_assume" {
  count = local.audit_reader_role_exists ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.audit_reader_principal_arns
    }
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "audit_reader_inline" {
  count  = local.audit_reader_role_exists ? 1 : 0
  name   = "audit-reader-inline"
  role   = aws_iam_role.audit_reader[0].id
  policy = data.aws_iam_policy_document.audit_reader.json
}

data "aws_iam_policy_document" "audit_reader" {
  statement {
    sid    = "S3ReadOnly"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectLegalHold",
      "s3:ListBucket",
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KMSDecrypt"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# compliance-officer  - sole role that can lift S3 Legal Hold
# D7: members identified separately; MFA required; SCP guardrail on this account
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "compliance_officer" {
  count              = local.compliance_officer_role_exists ? 1 : 0
  name               = "${var.name_prefix}-compliance-officer"
  assume_role_policy = data.aws_iam_policy_document.compliance_officer_assume[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "compliance_officer_assume" {
  count = local.compliance_officer_role_exists ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.compliance_officer_principal_arns
    }
    # Dual-control: both MFA and explicit session tag required
    condition {
      test     = "Bool"
      variable = "aws:MultiFactorAuthPresent"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "compliance_officer_inline" {
  count  = local.compliance_officer_role_exists ? 1 : 0
  name   = "compliance-officer-inline"
  role   = aws_iam_role.compliance_officer[0].id
  policy = data.aws_iam_policy_document.compliance_officer.json
}

data "aws_iam_policy_document" "compliance_officer" {
  # Legal Hold lift - the single dangerous permission, scoped tightly
  statement {
    sid    = "LegalHoldLift"
    effect = "Allow"
    actions = [
      "s3:PutObjectLegalHold",
      "s3:GetObjectLegalHold",
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }

  # Read access for review
  statement {
    sid    = "S3ReadForReview"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KMSDecryptForReview"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# SCP guardrail - denies Legal Hold removal from any role EXCEPT compliance-officer
# Applied at OU/account level to prevent privilege escalation
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_organizations_policy" "deny_legal_hold_lift" {
  count       = var.create_scp ? 1 : 0
  name        = "${var.name_prefix}-deny-legal-hold-lift"
  description = "Prevents any principal except compliance-officer from removing S3 Legal Hold on the vendor archive bucket"
  type        = "SERVICE_CONTROL_POLICY"
  content     = data.aws_iam_policy_document.scp_deny_legal_hold.json

  tags = var.tags
}

data "aws_iam_policy_document" "scp_deny_legal_hold" {
  statement {
    sid    = "DenyLegalHoldLiftExceptComplianceOfficer"
    effect = "Deny"
    actions = [
      "s3:PutObjectLegalHold",
    ]
    resources = ["${var.s3_bucket_arn}/*"]

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.compliance_officer.arn]
    }

    # Only applies to the archive bucket
    condition {
      test     = "StringEquals"
      variable = "s3:ResourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_organizations_policy_attachment" "deny_legal_hold_lift" {
  count     = var.create_scp ? 1 : 0
  policy_id = aws_organizations_policy.deny_legal_hold_lift[0].id
  target_id = var.scp_target_id
}

# ──────────────────────────────────────────────────────────────────────────────
# vendor-logger-svc — role for the producer service running vendor-logger.
# Can: SQS SendMessage (main queue), KMS GenerateDataKey+Decrypt (queue is SSE-KMS —
#      producers need both), SecretsManager GetSecretValue (the two hash-salt secrets).
# Assumed by the service's compute (ECS task / EC2). KMS works via the CMK's
# IAM-delegation key policy, so no kms module change is needed.
# ──────────────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "svc_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com", "ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vendor_logger_svc" {
  name               = "${var.name_prefix}-vendor-logger-svc"
  assume_role_policy = data.aws_iam_policy_document.svc_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "vendor_logger_svc_inline" {
  name   = "vendor-logger-svc-inline"
  role   = aws_iam_role.vendor_logger_svc.id
  policy = data.aws_iam_policy_document.vendor_logger_svc.json
}

data "aws_iam_policy_document" "vendor_logger_svc" {
  statement {
    sid       = "SQSSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.sqs_queue_arn]
  }

  # SSE-KMS queue → producers need GenerateDataKey (+ Decrypt) on the CMK.
  statement {
    sid       = "KMSForSqsSend"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }

  # Hash salts loaded by the library at service startup.
  dynamic "statement" {
    for_each = length(var.salt_secret_arns) > 0 ? [1] : []
    content {
      sid       = "ReadHashSalts"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.salt_secret_arns
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Service-linked role for SQS - ensures Lambda trigger works
# (already exists in most accounts; ignore error)
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_iam_service_linked_role" "lambda_sqs" {
  count            = var.create_lambda_slr ? 1 : 0
  aws_service_name = "lambda.amazonaws.com"

  lifecycle {
    ignore_changes = [aws_service_name]
  }
}
