data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# DLQ - receives messages after 5 failed processing attempts
# 14-day retention to allow Lambda replay after fixes
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  name                       = "${var.name_prefix}-vendor-events-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 300

  kms_master_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, { Name = "${var.name_prefix}-vendor-events-dlq" })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq_policy.json
}

data "aws_iam_policy_document" "dlq_policy" {
  statement {
    sid    = "AllowArchiverRedriveReceive"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.archiver_writer_role_arn]
    }
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.dlq.arn]
  }

  statement {
    sid    = "AllowMainQueueRedrive"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["sqs.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sqs_queue.main.arn]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Main queue - vendor-events-q
# Standard (not FIFO) - ordering not required, at-least-once delivery is fine
# Lambda consumes batches of 500 / 5-second window
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  name = "${var.name_prefix}-vendor-events-q"

  # Visibility timeout ≥ Lambda max execution timeout
  visibility_timeout_seconds = 360

  # Message retention - 4 days (lambda retries within this window)
  message_retention_seconds = 345600

  # Max size 256 KB - payloads ≤ 256 KB per HLD (oversize goes to S3 pointer in P1.5)
  max_message_size = 262144

  # Long poll interval - reduces empty-receive cost
  receive_wait_time_seconds = 20

  kms_master_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-vendor-events-q" })
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.main_queue_policy.json
}

data "aws_iam_policy_document" "main_queue_policy" {
  # Services (identity-api, los-api, payment-api) send messages via archiver-writer role
  statement {
    sid    = "AllowServiceSend"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = concat([var.archiver_writer_role_arn], var.service_role_arns)
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main.arn]
  }

  # Lambda archiver-writer consumes
  statement {
    sid    = "AllowArchiverConsume"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.archiver_writer_role_arn]
    }
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.main.arn]
  }

  # Deny non-TLS access
  statement {
    sid    = "DenyNonSSL"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.main.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# CH retry queue - vendor-archive-{env}-ch-retry-q
# Holds events whose ClickHouse INSERT failed (S3 write already succeeded, so this
# decouples CH outages from the main queue/DLQ). Standard, 14-day retention, no DLQ
# — a dedicated consumer drains/retries it (handles its own errors).
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "ch_retry" {
  name = "${var.name_prefix}-ch-retry-q"

  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 360
  receive_wait_time_seconds  = 20
  max_message_size           = 262144

  kms_master_key_id                 = var.kms_key_arn != "" ? var.kms_key_arn : null
  kms_data_key_reuse_period_seconds = 300

  tags = merge(var.tags, { Name = "${var.name_prefix}-ch-retry-q" })
}

resource "aws_sqs_queue_policy" "ch_retry" {
  queue_url = aws_sqs_queue.ch_retry.id
  policy    = data.aws_iam_policy_document.ch_retry_policy.json
}

data "aws_iam_policy_document" "ch_retry_policy" {
  statement {
    sid    = "AllowArchiverSendReceive"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.archiver_writer_role_arn]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.ch_retry.arn]
  }

  statement {
    sid    = "DenyNonSSL"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.ch_retry.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# CloudWatch alarms - per HLD §07 "Alert: depth > 0 for 5 min"
# ──────────────────────────────────────────────────────────────────────────────

# DLQ depth > 0 → indicates Lambda processing failures
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${var.name_prefix}-vendor-events-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300 # 5 minutes
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq.name
  }

  alarm_description = "Vendor events DLQ has messages - Lambda archiver processing failures"
  alarm_actions     = var.alert_sns_arns
  ok_actions        = var.alert_sns_arns

  tags = var.tags
}

# Main queue age > 60s → Lambda not keeping up
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  alarm_name          = "${var.name_prefix}-vendor-events-queue-age"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 60
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }

  alarm_description = "Vendor events queue message age > 60s - Lambda archiver falling behind"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}

# High queue depth → possible burst or Lambda cold start issue
resource "aws_cloudwatch_metric_alarm" "queue_depth_high" {
  alarm_name          = "${var.name_prefix}-vendor-events-depth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 5000
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.main.name
  }

  alarm_description = "Vendor events queue depth > 5k - possible ingest burst or Lambda issue"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}
