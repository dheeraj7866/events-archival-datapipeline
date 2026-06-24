# @finagle/vendor-logger — Hardening Plan

**Owner:** Pratyush Kumar  
**Updated:** 2026-05-29  
**Status:** Phase 0 in progress

---

## Phase 0 — Library hardening (CURRENT — before Lambda integration)

| # | Item | File(s) | Status |
|---|---|---|---|
| P0-1 | **Payload PII redaction** — mobile, email, PAN, account number deep-scan in requestPayload/responsePayload | `src/pii/payload-redactor.ts` | **In progress** |
| P0-2 | SQS drain re-enqueue on failure | `src/queue/sqs-drain.service.ts` | ✅ Done |
| P0-3 | requestHash computed pre-truncation | `src/http/vendor-http.service.ts` | ✅ Done |
| P0-4 | 256KB per-message SQS guard in `safeMsgBody()` | `src/queue/sqs-drain.service.ts` | ✅ Done |
| P0-5 | Metrics `http_status` label normalised to bands (2xx/4xx/5xx) | `src/metrics/vendor-metrics.service.ts` | **In progress** |
| P0-6 | `RingBuffer.capacity` getter (warn message fix) | `src/queue/ring-buffer.ts` | **In progress** |

---

## Phase 1 — Lambda consumer hardening (next sprint)

| # | Item | Severity | Notes |
|---|---|---|---|
| P1-1 | `reportBatchItemFailures` — per-record itemIdentifier, not top-level throw | Critical | Without this, one bad message retries all 500 |
| P1-2 | Per-record try/catch inside batch loop | Critical | Isolate poison pills |
| P1-3 | Schema validation of SQS message (Zod) | High | Catch version mismatches before processing |
| P1-4 | No `requestPayload`/`responsePayload` in CloudWatch logs | High | Only log requestId, vendorId, status |
| P1-5 | ClickHouse errors bubble up (not swallowed) | High | Silent swallow = empty Grafana, no alarm |
| P1-6 | Lambda timeout ≥ 3 min for 500-message batch | Medium | S3 PUT ~80ms × 500 = 40s minimum |
| P1-7 | aadhaarLast4 transport decision — raw vs hash in SQS (D4 adjacent) | High | Need counsel + arch decision before Lambda GA |

---

## Phase 2 — Infrastructure (Terraform)

| # | Item | Severity | Notes |
|---|---|---|---|
| P2-1 | DLQ on SQS queue + CloudWatch alarm `depth > 0` | High | Poison pills loop forever without DLQ |
| P2-2 | SQS SSE-KMS with `vendor-archive-pii-cmk` | High | Encrypts messages at rest in queue |
| P2-3 | Lambda IAM least privilege — no `s3:Delete*`, no `kms:Delete*` | High | See §06 in ARCHITECTURE.html for exact policy |
| P2-4 | CloudWatch log group KMS encryption | High | Lambda logs encrypted with s3-cmk |
| P2-5 | ClickHouse `ReplacingMergeTree(ingested_at)` — dedup on retry | High | SQS at-least-once guarantees duplicates |
| P2-6 | S3 bucket: block public access, Object Lock COMPLIANCE, CloudTrail data events | Critical | Compliance-critical, verify in Terraform |
| P2-7 | ClickHouse separate write/read users — Lambda gets INSERT only | Medium | Blast radius reduction |

---

## Phase 3 — Observability & reliability

| # | Item | Severity | Notes |
|---|---|---|---|
| P3-1 | Custom CloudWatch metrics: `vendor_archive_s3_writes_total`, `vendor_archive_ch_inserts_total` | Medium | EMF format from Lambda |
| P3-2 | Grafana dashboard: per-vendor failure rate, latency p50/p95/p99, buffer size | Medium | Query from ClickHouse |
| P3-3 | S3 → ClickHouse replay Lambda (re-ingest on CH outage / corruption) | Medium | Even a script counts |
| P3-4 | SQS queue depth CloudWatch alarm `> 5000` (drain backlog alert) | Medium | Catch ring buffer overflow situations |

---

## Phase 4 — Open decisions (gated on counsel / architecture)

| # | Decision | Blocker |
|---|---|---|
| D4 | Counsel sign-off on S3 Object Lock COMPLIANCE for RBI retention | Legal |
| D9 | DPDP §11 erasure vs Object Lock COMPLIANCE reconciliation | Legal |
| D7 | compliance-officer IAM role + MFA for Legal Hold removal | Architecture |
| D2 | ClickHouse HA: single MergeTree → ReplicatedMergeTree (P1.5) | Architecture |
| D3 | S3 cross-region replication DR target region | Architecture |

---

## PII field masking policy (post P0-1)

| Field type | In dedicated columns | In requestPayload / responsePayload |
|---|---|---|
| Aadhaar (full) | Never stored | Never — library rejects via ESLint rule |
| Aadhaar last-4 | HMAC-SHA256 hash | Deep-scan: `[AADHAAR_REDACTED]` |
| Mobile | HMAC-SHA256 hash + last-4 | Deep-scan: `*****3210` (last-4 visible) |
| PAN | First-3 + `****` + last-3 | Deep-scan: `ABC****34F` |
| Email | Not captured | Deep-scan: `p*****r@gmail.com` |
| Account number | Not captured | Deep-scan: `****1234` (last-4 visible) |
| Full name | Not captured | Not redacted (no reliable pattern) |
