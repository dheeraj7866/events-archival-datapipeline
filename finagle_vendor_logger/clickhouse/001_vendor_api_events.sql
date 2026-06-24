-- DEPRECATED — DO NOT USE. Canonical schema lives in vendor-archive/clickhouse/init.sql
-- (see CONVENTIONS.md §3). This file is kept for history only; it diverges from the
-- deployed schema (engine, columns, partitioning) and must not be applied or edited.
--
-- ClickHouse DDL for vendor API event archive
-- Run against the `vendor_archive` database.
-- Engine: ReplacingMergeTree deduplicates by request_id on merges (P2-5).
-- TTL: rows auto-expire after 90 days (hot tier). Frozen copies live in S3 forever.
-- ORDER BY is tuned for the two dominant query patterns:
--   1. vendor_id + event_date  → failure dashboards, cost tracking
--   2. user_id / application_id → customer support lookups
-- Partition by month keeps compaction cheap at ~15k events/day.

CREATE TABLE IF NOT EXISTS vendor_archive.vendor_api_events
(
    -- Identity
    request_id        UUID,
    correlation_id    String,
    created_at        DateTime64(3, 'UTC'),
    event_date        Date MATERIALIZED toDate(created_at),

    -- Source
    service           LowCardinality(String),
    environment       LowCardinality(String),

    -- Vendor
    vendor_id         LowCardinality(String),
    endpoint          LowCardinality(String),
    vendor_ref_id     Nullable(String),

    -- Loan context
    loan_lifecycle_stage  LowCardinality(String),
    application_id    Nullable(String),
    user_id           Nullable(String),
    consent_id        Nullable(String),

    -- PII — searchable indexes, never raw values
    pan_masked        Nullable(String),           -- ABC****34F
    mobile_hash       Nullable(String),           -- HMAC-SHA256(salt, E164(mobile))
    mobile_last4      Nullable(String),           -- 9876  (display only, not for lookup)
    aadhaar_last4_hash      Nullable(String),     -- HMAC-SHA256(aadhaarSalt, last4)
    aadhaar_last4_encrypted Nullable(String),     -- KMS CMK pii-cmk, set by Lambda

    -- Result
    status            LowCardinality(String),     -- SUCCESS|FAILURE|TIMEOUT|NETWORK_ERROR
    http_status       UInt16,
    latency_ms        UInt32,
    error_code        Nullable(String),
    error_message     Nullable(String),
    cost_paise        UInt32 DEFAULT 0,

    -- Payloads (redacted by Lambda PayloadRedactor before INSERT)
    request_payload   String,
    response_payload  String,
    payload_truncated Bool DEFAULT false,

    -- Audit chain
    request_hash      String,                     -- SHA-256 of raw request payload (pre-truncation)
    s3_request_key    String                       -- S3 object key for the raw (KMS-encrypted) event
)
ENGINE = ReplacingMergeTree(created_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY (vendor_id, event_date, request_id)
TTL event_date + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- Secondary indexes speed up the BFF's ad-hoc lookups without widening the primary key
CREATE INDEX IF NOT EXISTS idx_user_id          ON vendor_archive.vendor_api_events (user_id)          TYPE bloom_filter(0.01) GRANULARITY 4;
CREATE INDEX IF NOT EXISTS idx_application_id   ON vendor_archive.vendor_api_events (application_id)   TYPE bloom_filter(0.01) GRANULARITY 4;
CREATE INDEX IF NOT EXISTS idx_mobile_hash      ON vendor_archive.vendor_api_events (mobile_hash)      TYPE bloom_filter(0.01) GRANULARITY 4;
CREATE INDEX IF NOT EXISTS idx_pan_masked       ON vendor_archive.vendor_api_events (pan_masked)       TYPE bloom_filter(0.01) GRANULARITY 4;
CREATE INDEX IF NOT EXISTS idx_correlation_id   ON vendor_archive.vendor_api_events (correlation_id)   TYPE bloom_filter(0.01) GRANULARITY 4;
CREATE INDEX IF NOT EXISTS idx_status           ON vendor_archive.vendor_api_events (status)           TYPE set(10)            GRANULARITY 4;
