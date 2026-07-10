data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  audit_reader_role_exists = length(var.audit_reader_principal_arns) > 0
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

  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
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
# Cannot: write, delete, modify archive objects
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
      "s3:ListBucket",
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid    = "KMSDecrypt"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      resources = [var.kms_key_arn]
    }
  }
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
  dynamic "statement" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      sid       = "KMSForSqsSend"
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
      resources = [var.kms_key_arn]
    }
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
