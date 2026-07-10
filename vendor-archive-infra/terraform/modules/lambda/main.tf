data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Lambda function - vendor-archiver
# Runtime: Node.js 20.x
# Trigger: SQS, batch 500 / 5-second window
# Actions: batch INSERT to ClickHouse + parallel PutObject to S3
# ──────────────────────────────────────────────────────────────────────────────

# CloudWatch log group with retention before the function (avoids auto-created group)
resource "aws_cloudwatch_log_group" "archiver" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = var.tags
}

resource "aws_lambda_function" "archiver" {
  function_name = var.function_name
  description   = "Batch-inserts vendor API events from SQS into ClickHouse and S3 archive"

  runtime       = "nodejs20.x"
  architectures = ["arm64"] # Graviton - ~20% cheaper + faster cold start
  handler       = "index.handler"

  # Deployment package - built and zipped via CI
  filename         = var.lambda_zip_path
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  role        = var.execution_role_arn
  timeout     = 300 # 5 min - batch of 500 events with CH insert + S3 parallel writes
  memory_size = 512

  # VPC config - Lambda must reach ClickHouse EC2 on private subnet
  vpc_config {
    subnet_ids         = var.vpc_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      CLICKHOUSE_HOST     = var.clickhouse_host
      CLICKHOUSE_PORT     = tostring(var.clickhouse_port)
      CLICKHOUSE_DATABASE = var.clickhouse_database
      CLICKHOUSE_USER     = var.clickhouse_user
      # Password in Secrets Manager - always uses the secret created by this module
      CLICKHOUSE_SECRET_ARN = aws_secretsmanager_secret.clickhouse_password.arn
      S3_BUCKET             = var.s3_bucket_name
      S3_REGION             = data.aws_region.current.name
      KMS_KEY_ARN           = var.kms_key_arn
      ENVIRONMENT           = var.environment
      # Failed ClickHouse INSERTs are re-routed here instead of failing the SQS message
      CH_RETRY_QUEUE_URL = var.ch_retry_queue_url
    }
  }

  tracing_config {
    mode = "Active"
  }

  # No dead_letter_config here — this Lambda is SQS-triggered.
  # DLQ for failed messages is configured on the SQS queue via redrive_policy,
  # not on the Lambda function (which only applies to async invocations).

  # reserved_concurrent_executions intentionally omitted to avoid account-level
  # conflicts; use event source mapping `scaling_config` to cap concurrency.

  depends_on = [aws_cloudwatch_log_group.archiver]

  tags = var.tags
}

# SQS event source mapping - batch 500, 5-second window
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = var.sqs_queue_arn
  function_name    = aws_lambda_function.archiver.arn
  enabled          = true

  batch_size                         = 500
  maximum_batching_window_in_seconds = 5

  # Report partial batch failures - successful records in a batch aren't retried
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = 10 # cap Lambda concurrency to protect ClickHouse
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Security group for Lambda - egress to ClickHouse SG + S3/SQS via VPC endpoints
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "lambda" {
  name        = "${var.function_name}-sg"
  description = "Lambda vendor-archiver - egress to ClickHouse + AWS services"
  vpc_id      = var.vpc_id

  egress {
    description     = "ClickHouse native protocol"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [var.clickhouse_sg_id]
  }

  egress {
    description     = "ClickHouse HTTP interface"
    from_port       = 8123
    to_port         = 8123
    protocol        = "tcp"
    security_groups = [var.clickhouse_sg_id]
  }

  egress {
    description = "HTTPS to AWS services (S3, SQS, KMS, Secrets Manager) via VPC endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.function_name}-sg" })
}

# ──────────────────────────────────────────────────────────────────────────────
# CloudWatch alarms for Lambda health
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.function_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.archiver.function_name
  }

  alarm_description = "Lambda vendor-archiver error count > 5 in 1 min"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration_p99" {
  alarm_name          = "${var.function_name}-duration-p99"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 250000 # 250 seconds - approaching 300s timeout
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.archiver.function_name
  }

  alarm_description = "Lambda vendor-archiver p99 duration > 250s - approaching timeout"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.function_name}-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.archiver.function_name
  }

  alarm_description = "Lambda vendor-archiver throttling detected"
  alarm_actions     = var.alert_sns_arns

  tags = var.tags
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets Manager - ClickHouse password
# ──────────────────────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "clickhouse_password" {
  name        = "${var.name_prefix}/clickhouse/archiver-password"
  description = "ClickHouse password for the vendor-archiver Lambda"
  kms_key_id  = var.kms_key_arn != "" ? var.kms_key_arn : null

  recovery_window_in_days = 0

  tags = var.tags
}

resource "random_password" "clickhouse_password" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret_version" "clickhouse_password" {
  secret_id     = aws_secretsmanager_secret.clickhouse_password.id
  secret_string = random_password.clickhouse_password.result
}

resource "terraform_data" "clickhouse_password_cleanup" {
  input = aws_secretsmanager_secret.clickhouse_password.name

  provisioner "local-exec" {
    when    = destroy
    command = "aws secretsmanager delete-secret --region ap-south-1 --secret-id ${self.input} --force-delete-without-recovery >/dev/null 2>&1 || true"
  }
}

# Grant Lambda execution role access to the secret
resource "aws_secretsmanager_secret_policy" "clickhouse_password" {
  secret_arn = aws_secretsmanager_secret.clickhouse_password.arn
  policy     = data.aws_iam_policy_document.secret_policy.json
}

data "aws_iam_policy_document" "secret_policy" {
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.execution_role_arn]
    }
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.clickhouse_password.arn]
  }
}
