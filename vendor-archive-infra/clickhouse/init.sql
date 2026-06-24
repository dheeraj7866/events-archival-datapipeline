-- ClickHouse schema for vendor_api_events
-- Run this once after ClickHouse is up: clickhouse-client < init.sql
--
-- MVP: MergeTree (single node)
-- Phase 1.5: swap to ReplicatedMergeTree after HA cluster is provisioned

CREATE DATABASE IF NOT EXISTS vendor_archive;

USE vendor_archive;

CREATE TABLE IF NOT EXISTS vendor_api_events
(
    -- ── Schema version (producer contract; Lambda skips events where != 1) ─────
    schema_version          UInt8 DEFAULT 1,

    -- ── Identity ──────────────────────────────────────────────────────────────
    request_id              UUID,

    -- ── Timestamps ────────────────────────────────────────────────────────────
    created_at              DateTime64(3, 'Asia/Kolkata'),
    ingested_at             DateTime64(3, 'Asia/Kolkata'),

    -- ── Routing ───────────────────────────────────────────────────────────────
    service                 LowCardinality(String),   -- identity-api | los-api | payment-api
    environment             LowCardinality(String) DEFAULT '',  -- staging | prod
    vendor_id               LowCardinality(String),   -- digitap | signzy | easebuzz | synoriq | icici-bank | internal-bre
    endpoint                LowCardinality(String),   -- e.g. pan-kyc-verify

    -- ── Vendor's own reference ────────────────────────────────────────────────
    vendor_ref_id           String DEFAULT '',        -- vendor txn ID for support/reconciliation

    -- ── Loan context (D1 LOCKED — see CONVENTIONS.md §4) ──────────────────────
    loan_lifecycle_stage    Enum8('LEAD'=1, 'SELFIE'=2, 'KYC'=3, 'PAN_AADHAAR_SEED'=4, 'LOCATION_BRE'=5, 'BUREAU_BRE'=6, 'BANK_BRE'=7, 'REPEAT_BRE'=8, 'UNDERWRITING'=9, 'DISBURSED'=10, 'REPAID'=11, 'OVERDUE'=12, 'CLOSED'=13, 'WRITTEN_OFF'=14, 'LMS_QUERY'=15, 'PENNY_DROP'=16, 'LOAN_AGREEMENT'=17, 'DISBURSEMENT'=18),
    loan_application_number Nullable(String),
    user_id                 String DEFAULT '',

    -- ── PII derivatives — no raw PAN / Aadhaar / mobile stored here ──────────
    pan_masked              String DEFAULT '',        -- AAAPA9999A → AAAPA****A
    mobile_hash             String DEFAULT '',        -- SHA-256 of E.164
    mobile_last4            String DEFAULT '',
    aadhaar_last4_hash      String DEFAULT '',        -- D2: SHA-256 of last-4
    aadhaar_last4_encrypted String DEFAULT '',        -- D2: KMS-encrypted ciphertext

    -- ── Consent (D5: nullable until P1.5 consent_records table ships) ─────────
    consent_id              String DEFAULT '',        -- FK to Postgres consent_records

    -- ── Outcome ───────────────────────────────────────────────────────────────
    status                  LowCardinality(String),   -- SUCCESS | FAILURE | TIMEOUT | NETWORK_ERROR (LOGGER_ERROR is metrics-only)
    http_status             Nullable(UInt16),
    latency_ms              UInt32,
    error_code              String DEFAULT '',
    error_message           String DEFAULT '',        -- vendor/transport error text (no PII — see redaction policy)

    -- ── S3 pointers (always written — hot copies dropped by column TTL) ───────
    s3_request_key          String,
    s3_response_key         String,

    -- ── Hot-tier payload copies (30d column TTL) ─────────────────────────────
    request_payload         String DEFAULT '' CODEC(ZSTD(3)),  -- REDACTED copy (raw lives in S3)
    response_payload        String DEFAULT '' CODEC(ZSTD(3)),  -- REDACTED copy (raw lives in S3)
    payload_truncated       UInt8 DEFAULT 0,

    -- ── Audit chain ───────────────────────────────────────────────────────────
    request_hash            String DEFAULT ''         -- SHA-256 of the raw (pre-truncation) request payload
)
-- Dedup purely by request_id. ReplacingMergeTree with no version column keeps the
-- last row merged for a given ORDER BY key. SQS at-least-once + Lambda retries can
-- deliver the same request_id twice; this collapses it on the next background merge
-- (use FINAL for read-time dedup). Monthly partitions keep compaction cheap.
ENGINE = ReplacingMergeTree()
PARTITION BY toYYYYMM(created_at)
ORDER BY (request_id)
-- Row TTL: 90 days. Row is deleted but S3 objects remain accessible forever.
TTL created_at + INTERVAL 90 DAY
SETTINGS
    ttl_only_drop_parts = 1,
    index_granularity   = 8192,
    min_rows_for_wide_part = 1000000;


-- Column TTL for hot-tier payload copies (30 days)
ALTER TABLE vendor_api_events
    MODIFY COLUMN request_payload  String DEFAULT '' CODEC(ZSTD(3)) TTL created_at + INTERVAL 30 DAY,
    MODIFY COLUMN response_payload String DEFAULT '' CODEC(ZSTD(3)) TTL created_at + INTERVAL 30 DAY;


-- ── Materialized view: per-vendor failure counters (for Grafana fast path) ────
CREATE TABLE IF NOT EXISTS vendor_failure_counts_1m
(
    window_start    DateTime,
    vendor_id       LowCardinality(String),
    endpoint        LowCardinality(String),
    service         LowCardinality(String),
    status          LowCardinality(String),
    total           AggregateFunction(count, UInt64),
    total_latency   AggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree()
ORDER BY (window_start, vendor_id, endpoint, service, status)
TTL window_start + INTERVAL 30 DAY;


CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_failure_counts_mv
TO vendor_failure_counts_1m
AS
SELECT
    toStartOfMinute(created_at)         AS window_start,
    vendor_id,
    endpoint,
    service,
    status,
    countState()                        AS total,
    sumState(toUInt64(latency_ms))      AS total_latency
FROM vendor_api_events
GROUP BY window_start, vendor_id, endpoint, service, status;


-- ── Per-vendor materialized views ─────────────────────────────────────────────
-- One isolated MergeTree table per vendor (SELECT *), for vendor-scoped queries.
-- These fire on every insert AS the archiver user, hence the broad grants below.
CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_archive.mv_karza
ENGINE = MergeTree() ORDER BY (created_at) POPULATE
AS SELECT * FROM vendor_archive.vendor_api_events WHERE vendor_id = 'karza';

CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_archive.mv_easebuzz
ENGINE = MergeTree() ORDER BY (created_at) POPULATE
AS SELECT * FROM vendor_archive.vendor_api_events WHERE vendor_id = 'easebuzz';

CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_archive.mv_nsdl
ENGINE = MergeTree() ORDER BY (created_at) POPULATE
AS SELECT * FROM vendor_archive.vendor_api_events WHERE vendor_id = 'nsdl';

CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_archive.mv_crif
ENGINE = MergeTree() ORDER BY (created_at) POPULATE
AS SELECT * FROM vendor_archive.vendor_api_events WHERE vendor_id = 'crif';

CREATE MATERIALIZED VIEW IF NOT EXISTS vendor_archive.mv_bank_statement_analyser
ENGINE = MergeTree() ORDER BY (created_at) POPULATE
AS SELECT * FROM vendor_archive.vendor_api_events WHERE vendor_id = 'bank-statement-analyser';


-- ── User + permissions ────────────────────────────────────────────────────────
CREATE USER IF NOT EXISTS archiver IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER';

-- archiver inserts events AND drives every materialized view (failure-counts +
-- per-vendor mv_*), all executed AS archiver:
--   • per-vendor MVs use SELECT *  → needs SELECT on the full base table
--   • each MV writes to its own target/inner table → needs INSERT across the DB
-- NOTE: broader than the earlier column-scoped grant — with SELECT * MVs the archiver
-- can now read pan_masked/payloads. To keep that read scope locked down, change the
-- per-vendor MVs to project only non-PII columns instead of SELECT *.
GRANT INSERT ON vendor_archive.* TO archiver;
GRANT SELECT ON vendor_archive.vendor_api_events TO archiver;

-- reader: SELECT only (Grafana datasource)
CREATE USER IF NOT EXISTS grafana_reader IDENTIFIED BY 'CHANGE_ME_IN_SECRETS_MANAGER';

GRANT SELECT ON vendor_archive.* TO grafana_reader;

-- ── Smoke test query (run after init) ────────────────────────────────────────
-- SELECT count() FROM vendor_archive.vendor_api_events;
