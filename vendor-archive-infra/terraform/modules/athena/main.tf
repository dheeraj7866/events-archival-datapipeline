data "aws_region" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# Athena cold-tier query layer over the S3 archive (meta.json sidecars).
# Uses partition projection (no crawler / no MSCK) keyed on year/month/day/vendor_id,
# matching the Lambda S3 layout:
#   {year}/{month}/{day}/{vendor_id}/{endpoint}/{user_id}/{request_id}/meta.json
#
# NOTE: vendor_id is a PARTITION key only (not a regular column) — Hive/Glue forbids
# a name appearing in both. The value comes from the path; meta.json also carries it
# (ignored for the column, used as evidence).
# ──────────────────────────────────────────────────────────────────────────────

# Query-results bucket (separate from the Object-Locked archive — results must be deletable)
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.name_prefix}-athena-results"
  force_destroy = false
  tags          = merge(var.tags, { Name = "${var.name_prefix}-athena-results" })
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# ── Athena workgroup ──────────────────────────────────────────────────────────
resource "aws_athena_workgroup" "vendor_archive" {
  name = "${var.name_prefix}-wg"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"
      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_key_arn
      }
    }
  }

  tags = var.tags
}

# ── Glue catalog database + projected external table ──────────────────────────
resource "aws_glue_catalog_database" "vendor_archive" {
  name = replace("${var.name_prefix}_cold", "-", "_")
}

resource "aws_glue_catalog_table" "vendor_events_cold" {
  name          = "vendor_events_cold"
  database_name = aws_glue_catalog_database.vendor_archive.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification              = "json"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2026,2040"
    "projection.year.digits"    = "4"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "projection.vendor_id.type" = "injected"
    # $${...} escapes Terraform interpolation so Athena receives literal ${...}
    "storage.location.template" = "s3://${var.archive_bucket}/$${year}/$${month}/$${day}/$${vendor_id}/"
  }

  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }
  partition_keys {
    name = "day"
    type = "string"
  }
  partition_keys {
    name = "vendor_id"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${var.archive_bucket}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
      parameters            = { "ignore.malformed.json" = "true" }
    }

    dynamic "columns" {
      for_each = {
        schema_version          = "int"
        request_id              = "string"
        correlation_id          = "string"
        created_at              = "string"
        service                 = "string"
        environment             = "string"
        endpoint                = "string"
        loan_lifecycle_stage    = "string"
        loan_application_number = "string"
        user_id                 = "string"
        pan_masked              = "string"
        mobile_last4            = "string"
        aadhaar_last4_hash      = "string"
        consent_id              = "string"
        status                  = "string"
        http_status             = "int"
        latency_ms              = "int"
        request_hash            = "string"
      }
      content {
        name = columns.key
        type = columns.value
      }
    }
  }
}
