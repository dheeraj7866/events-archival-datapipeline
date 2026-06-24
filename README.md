# Vendor Archive Data Pipeline

## Project Overview

This repository implements a vendor API archival and monitoring pipeline for the `@finagle/vendor-logger` system. It includes:

- `vendor_logger`: a NestJS shared library that captures vendor API calls, performs PII-safe event logging, and publishes events to SQS.
- `vendor-archive-infra`: Terraform infrastructure for staging/prod, including VPC, SQS, Lambda archiver, ClickHouse, S3 archive, KMS, IAM, and monitoring.

The pipeline is designed to provide:

- auditable vendor event storage
- compliance-safe data handling
- hot-tier analytics in ClickHouse
- cold-tier audit archive in S3
- operational observability via CloudTrail and alarms

## Architecture Overview

### High-level components

- `@finagle/vendor-logger` library
  - Instrumented by borrower-facing NestJS services
  - Captures vendor API payloads and metadata
  - Preserves fail-open behavior for vendor integration
  - Sends events into a local ring buffer and then to SQS

- AWS staging/prod infrastructure
  - `SQS` standard queue stores archive events
  - `Lambda` vendor-archiver consumes SQS batches
  - `ClickHouse` stores redacted, queryable event metadata
  - `S3` stores raw payload archive files
  - `KMS` protects encryption keys
  - `IAM` controls least privilege access
  - `CloudTrail` and CloudWatch provide audit and alerting

### Logical architecture

```
               +-----------------------------+
               |  NestJS application service  |
               |  (identity-api / los-api /   |
               |   payment-api)               |
               +-------------+---------------+
                             |
         in-process          | Vendor API call and event
         ring buffer         | capture via @finagle/vendor-logger
                             |
                             v
                    +----------------+
                    | SQS queue      |
                    | (fan-in buffer)|
                    +----------------+
                             |
                             | Lambda batch consumer
                             v
                +-----------------------------+
                | Lambda vendor-archiver      |
                | Node.js 20, arm64, VPC ENI   |
                +-------------+---------------+
                              |
            +-----------------+-----------------+
            |                                   |
            v                                   v
   +----------------------+       +-------------------------------+
   | ClickHouse EC2       |       | S3 archive bucket             |
   | vendor_archive       |       | vendor-archive-staging-aps2   |
   | (hot analytics)      |       | (cold archive)                |
   +----------------------+       +-------------------------------+
```

## End-to-End Flow

1. A NestJS service makes a vendor HTTP request through `VendorHttpService.call()`.
2. The library builds a `VendorApiEvent` that includes request metadata, timing, error status, and redacted PII.
3. The event is appended to a bounded in-process ring buffer.
4. `SqsDrainService` drains the ring buffer asynchronously and sends batches of events to SQS.
5. The Lambda archiver consumes SQS messages in batches, writes raw payloads to S3, and inserts event metadata into ClickHouse.
6. ClickHouse stores hot data for analytics and alerting; S3 preserves raw data indefinitely for audit and recovery.
7. Grafana or other analytics tools query ClickHouse for dashboards and operational metrics.
8. CloudTrail logs S3 and data events for audit, while alarms monitor read spikes and DLQ/backlog conditions.

## Data Flow Details

### `vendor_logger` library

- Built as a shared NestJS module.
- Exposes `VendorHttpService.call()` for vendor integrations.
- Performs PII redaction before event submission.
- Uses a ring buffer to keep the sync hot path low latency (<1ms on enqueue).
- Drains asynchronously to SQS with backoff and batch retries.

### Lambda archiver

- Reads SQS events in batches.
- Writes raw request/response payloads to S3.
- Writes metadata to ClickHouse.
- Uses KMS for encryption and AWS Secrets Manager for ClickHouse credentials.

### ClickHouse schema

The ClickHouse schema in `vendor-archive-infra/clickhouse/init.sql` includes:

- `vendor_api_events` table:
  - `schema_version`, `request_id`
  - `created_at`, `ingested_at`
  - `service`, `environment`, `vendor_id`, `endpoint`
  - `loan_lifecycle_stage`, `loan_application_number`, `user_id`
  - `pan_masked`, `mobile_hash`, `mobile_last4`, `aadhaar_last4_hash`, `aadhaar_last4_encrypted`
  - `status`, `http_status`, `latency_ms`, `error_code`, `error_message`
  - `s3_request_key`, `s3_response_key`
  - `request_payload`, `response_payload`, `payload_truncated`
  - `request_hash`
- `vendor_failure_counts_1m` aggregation table and materialized view for metrics.
- Vendor-specific materialized views for per-vendor query isolation.

## Folder Contents

- `vendor_logger/`
  - `src/`: shared library code
  - `test/`: unit and integration tests
  - `Dockerfile-dev` / `Dockerfile-prod`: Docker build targets
  - `docker-compose-dev.yml`: local dev compose setup
  - `Jenkinsfile-dev` / `Jenkinsfile-prod`: deployment CI flows
  - `.env.dev` / `.env.prod`: runtime config templates

- `vendor-archive-infra/`
  - `terraform/environments/staging/`: staging Terraform entrypoint
  - `terraform/environments/prod/`: production Terraform entrypoint
  - `terraform/modules/`: reusable Terraform modules
  - `clickhouse/init.sql`: ClickHouse schema and materialized view definitions

## Architecture and Schema Diagram

### Flow diagram

```
PRODUCERS  ->  SQS  ->  Lambda  ->  CLICKHOUSE
                              |
                              v
                             S3
```

### Schema diagram

```
vendor_api_events
├── request_id
├── created_at
├── ingested_at
├── service
├── environment
├── vendor_id
├── endpoint
├── vendor_ref_id
├── loan_lifecycle_stage
├── loan_application_number
├── user_id
├── pan_masked
├── mobile_hash
├── mobile_last4
├── aadhaar_last4_hash
├── aadhaar_last4_encrypted
├── consent_id
├── status
├── http_status
├── latency_ms
├── error_code
├── error_message
├── s3_request_key
├── s3_response_key
├── request_payload
├── response_payload
├── payload_truncated
└── request_hash
```

## Deployment Notes

- `vendor_logger` is packaged as an NPM module for NestJS host applications.
- Staging uses `ap-south-2` and production uses `ap-south-1` for regional availability.
- Terraform state is stored in S3 and locked using `use_lockfile`.
- Secrets such as hash salts and ClickHouse credentials are stored in AWS Secrets Manager.

## Running Locally

For the library:

```bash
cd vendor_logger
npm install
npm test
npm run build
```

For infrastructure validation:

```bash
cd vendor-archive-infra/terraform/environments/staging
terraform init
terraform plan
```

## Key Design Principles

- **Fail-open**: vendor logging must never break the primary business flow.
- **PII-safe**: sensitive fields are hashed or masked before storage.
- **Hot/cold separation**: ClickHouse for analytics, S3 for archive.
- **Least privilege**: Lambda and other roles only get required permissions.
- **Testability**: infrastructure and library are designed for staging-first validation.

## References

- `vendor-archive-infra/README.md`
- `vendor_logger/CLAUDE.md`
- `vendor_logger/ARCHITECTURE.html`
- `vendor-archive-infra/clickhouse/init.sql`
