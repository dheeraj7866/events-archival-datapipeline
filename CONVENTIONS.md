# Vendor API Archiving — Integration Conventions & Contract

**Status:** Authoritative · **Updated:** 2026-05-29 · **Region:** `ap-south-2` (Hyderabad)
**Scope:** Binds `vendor-logger` (producer library) **and** `vendor-archive` (Lambda + infra).

> This file is the single source of truth for the cross-repo contract. When code, `ARCHITECTURE.html`,
> `HARDENING_PLAN.md`, or `README.md` disagree, **this file wins**. Update this file *first*, then the code.
> Its purpose is to stop mid-flight drift while we close the integration. See [plan.md](plan.md) for tracked work.

---

## 0. Architecture in one line

`VendorHttpService.call()` → builds camelCase `VendorApiEvent` → `RingBuffer` (fail-open, <1ms) →
`SqsDrainService` (async, 100ms) maps to **snake_case wire** (`toWireEvent`) → **SQS (snake_case JSON)** →
**Lambda `vendor-archiver`** → **S3 (raw, Object Lock COMPLIANCE)** *then* → **ClickHouse (snake_case, redacted
payloads)** → Grafana.

Fan-in: 3 producers (`identity-api`, `los-api`, `payment-api`) → 1 queue. Fan-out: 1 Lambda → 2 sinks, **S3 first**.

---

## 1. The wire contract (SQS message) — **CANONICAL: snake_case**

**Decision (D-WIRE, revised 2026-05-29):** The SQS wire is **snake_case**, 1:1 with the ClickHouse columns the
producer owns. The library keeps `VendorApiEvent` in **camelCase internally** (TS ergonomics; all library code,
metrics, and tests use it), and maps to the wire shape **at the SQS boundary only** via `toWireEvent()`. This was
switched from camelCase-on-the-wire while there were still **zero live producers/consumers** — the cheapest moment
to make the wire match the table.

Source of truth for the wire shape: [`vendor_logger/src/types/vendor-event.wire.ts`](vendor_logger/src/types/vendor-event.wire.ts) → `interface VendorApiEventWire` + `toWireEvent()`. The internal camelCase type stays in [`vendor-event.types.ts`](vendor_logger/src/types/vendor-event.types.ts).

| Field (snake_case wire) | Type | Nullable on wire | Notes |
|---|---|---|---|
| `request_id` | string (uuid v4) | no | |
| `correlation_id` | string | no | `'unknown'` if no correlation context |
| `created_at` | string (ISO-8601, `Z`/UTC) | no | |
| `service` | string | no | producer id (`identity-api`…) |
| `environment` | string | no | `staging` / `prod` |
| `vendor_id` | string | no | |
| `endpoint` | string | no | |
| `vendor_ref_id` | string | yes | |
| `loan_lifecycle_stage` | enum | no | see §4 |
| `application_id` | string | yes | |
| `user_id` | string | yes | |
| `pan_masked` | string | yes | `ABC****34F` |
| `mobile_hash` | string | yes | HMAC-SHA256(E.164) |
| `mobile_last4` | string | yes | |
| `aadhaar_last4_hash` | string | yes | HMAC-SHA256(last4) |
| `consent_id` | string | yes | |
| `status` | enum | no | see §4 |
| `http_status` | number | no | `0` = no response |
| `latency_ms` | number | no | |
| `error_code` | string | yes | |
| `error_message` | string | yes | |
| `cost_paise` | number | no | defaults `0` |
| `request_payload` | **string** | no | already `JSON.stringify`'d by library; may end with `...[TRUNCATED]` or be `[OVERSIZED]` |
| `response_payload` | **string** | no | same |
| `payload_truncated` | boolean | no | |
| `request_hash` | string | no | SHA-256 of the **pre-truncation** request payload (audit anchor) |

**Rules:**
- The wire is **snake_case**; field names match the ClickHouse columns the producer owns 1:1.
- Payloads are **strings on the wire** (the library serializes them). The Lambda must **not** re-`JSON.stringify` them.
- Producers must keep `JSON.stringify(toWireEvent(event))` ≤ 256 KB; oversize → payloads become `[OVERSIZED]` (`safeMsgBody`).
- Wire mapping lives in **exactly one place** (`toWireEvent`); add a new field to the internal type, the wire type, and the mapper together. Additive/optional only.

---

## 2. The Lambda transform — **CANONICAL**

The wire is already snake_case (§1), so the Lambda does **no field renaming**. Its job (`mapToClickHouseRow` in
`vendor-archive/lambda/vendor-archiver/src/index.ts`) is: pass the wire fields through, add the Lambda-owned
columns, redact payloads, and coerce types.

### 2.1 Wire → ClickHouse row

| Wire field | ClickHouse column | Transform |
|---|---|---|
| (all producer fields) | same snake_case name | passthrough; optional string fields `?? ''` |
| — | `ingested_at` | Lambda `now()` (UTC ISO) |
| — | `s3_request_key` / `s3_response_key` | generated after S3 write (§5) |
| — | `aadhaar_last4_encrypted` | `''` **(deferred — gated on D2; do NOT fabricate KMS)** |
| `request_payload` / `response_payload` | same | **redacted** for CH (§6) — raw goes to S3 |
| `http_status` / `cost_paise` | same | `?? null` (nullable columns) |
| `payload_truncated` | `payload_truncated` | `? 1 : 0` (bool → UInt8) |
| `status`, `created_at`, `request_hash`, … | same | passthrough |

### 2.2 Ordering & write contract (non-negotiable)
1. **S3 first, ClickHouse second.** S3 is the compliance truth; CH is a queryable index. If CH fails, S3 + Athena recover.
2. S3 stores **raw** payloads (the library's strings, decoded). ClickHouse stores **redacted** payloads (§6).
3. Per-record failures → `ReportBatchItemFailures` (`itemIdentifier`), never a top-level throw for one bad record.
4. CH INSERT failure → return **all** records as failures (whole batch retried). Keep `async_insert=0` so the
   INSERT is acknowledged synchronously and a failure is real (don't fire-and-forget a compliance insert).

### 2.3 Shared types
The Lambda must use the **same** wire type (`VendorApiEventWire`) and the **same** `PayloadRedactor` as the
library — no hand-redrawn copies that can drift.
- **Target:** publish `vendor-logger` to CodeArtifact (D5) and `import { VendorApiEventWire, PayloadRedactor } from 'vendor-logger'`.
- **Interim (until D5/CodeArtifact in ap-south-2):** a single vendored mirror under `lambda/vendor-archiver/src/contract/` copied by a build step from the library, with a header comment pointing here. **One** copy, build-synced — not a freehand rewrite.

---

## 3. ClickHouse schema — **CANONICAL: `vendor-archive/clickhouse/init.sql`**

**Decision (D-SCHEMA):** There is exactly **one** schema, in the infra repo:
[`vendor-archive/clickhouse/init.sql`](vendor-archive/clickhouse/init.sql).
The library-repo DDL [`vendor_logger/clickhouse/001_vendor_api_events.sql`](vendor_logger/clickhouse/001_vendor_api_events.sql)
is **deprecated** — mark it `-- DEPRECATED: see vendor-archive/clickhouse/init.sql` and stop editing it.

Required changes to the canonical schema (tracked in plan.md, applied infra-later):
- **Add columns** the library produces and compliance needs: `environment LowCardinality(String) DEFAULT ''`,
  `error_message String DEFAULT ''`, `request_hash String DEFAULT ''`.
- **Engine → `ReplacingMergeTree(ingested_at)`** (HARDENING P2-5). Dedup key is the `ORDER BY`; ensure
  `request_id` is in `ORDER BY` so SQS at-least-once + Lambda retries collapse on merge.
- The Lambda `ClickHouseRow` must stay **column-for-column identical** to this table. Adding a column means:
  update init.sql → update `ClickHouseRow` + mapping (§2.1) in the **same** change.

Type rules: `request_id UUID`; timestamps `DateTime64(3)`; counts `UInt32`; `http_status Nullable(UInt16)`;
`cost_paise Nullable(UInt32)`; `payload_truncated UInt8` (0/1); enums stored as `LowCardinality(String)` (no CH-level enum enforcement — validity is the producer's job, §4).

Grafana reads this table directly (ClickHouse datasource); column names here are a public API for dashboards.

---

## 4. Enums — **LOCKED**

`status` (`VendorStatus`) — exactly these 5:
`SUCCESS | FAILURE | TIMEOUT | NETWORK_ERROR | LOGGER_ERROR`
- `LOGGER_ERROR` is **metrics-only** and is never written as an event `status` (the logger-failure path is a
  swallowed catch). Dashboards that compute failure rate use `FAILURE|TIMEOUT|NETWORK_ERROR`.

`loanLifecycleStage` (`LoanLifecycleStage`) — D1, locked, 14 values, in order:
`LEAD → SELFIE → KYC → PAN_AADHAAR_SEED → LOCATION_BRE → BUREAU_BRE → BANK_BRE → REPEAT_BRE → UNDERWRITING → DISBURSED → REPAID | OVERDUE | CLOSED | WRITTEN_OFF`

Any comment in `init.sql` or dashboards listing a shorter set is stale — reconcile to the above.

---

## 5. S3 object layout — **CANONICAL: as implemented**

Key: `YYYY/MM/DD/{vendorId}/{endpointSanitized}/{requestId}/{request|response}.json.gz`
- Date-prefix first → aligns with lifecycle transitions (IA@90d, Deep Archive@365d) and TTL.
- `endpointSanitized`: strip leading `/` and replace inner `/` with `_` (an endpoint like `/kyc/verify` must
  not create extra path segments). **Producers/Lambda must sanitize** — tracked in plan.md.
- Body: gzip of `{ meta:{…}, payload }`, `ContentType: application/gzip`, `ContentEncoding: gzip`.
- Bucket policy **requires** every PUT to set `ServerSideEncryption: aws:kms` **and** `ObjectLockLegalHoldStatus: ON`
  (else `DenyUnencryptedPut` / `DenyPutWithoutLegalHold`). The Lambda's `PutObjectCommand` already sets both.
- ⚠️ The explicit second `PutObjectLegalHold` call may be **denied by the SCP** that reserves
  `s3:PutObjectLegalHold` for `compliance-officer`. Setting the hold inline on `PutObject` is sufficient —
  drop the redundant call or exempt the archiver role. Tracked in plan.md.

---

## 6. PII policy — **CANONICAL**

**Decision (D-PII): S3 raw, ClickHouse redacted, redaction done by the Lambda.**
- Library ships **raw** payload strings (keeps the <1ms hot path clean; no deep-scan on the producer).
- Lambda writes **raw** to S3 (full-fidelity RBI audit, KMS + Object Lock).
- Lambda applies `PayloadRedactor.redact()` to payloads **before** the ClickHouse INSERT, so no plaintext PII
  lands in the queryable tier.
- **Fail-closed on unparseable payloads:** the library always `JSON.stringify`s payloads, so a payload only
  fails to parse when it was **truncated** or `[OVERSIZED]`. `PayloadRedactor` only deep-scans *embedded* Aadhaar
  (PAN/mobile/email are matched as whole field values), so an unparseable string could leak embedded PAN/mobile.
  Therefore the Lambda stores `[REDACTED:UNPARSEABLE]` in ClickHouse for any non-JSON payload — the full raw copy
  remains in S3. **Follow-up (library P0-1):** extend the redactor to scan embedded PAN/mobile/email so truncated
  payloads can be stored redacted instead of dropped.

Dedicated PII columns (always derived in the library, never raw):

| Field | Column | Method |
|---|---|---|
| Aadhaar (full) | — | never stored anywhere |
| Aadhaar last-4 | `aadhaar_last4_hash` | HMAC-SHA256(`aadhaarHashSalt`) |
| Aadhaar last-4 (encrypted) | `aadhaar_last4_encrypted` | KMS — **DEFERRED**, gated on **D2**. Leave `''`; do not ship a fake. |
| Mobile (full) | — | never stored |
| Mobile | `mobile_hash` + `mobile_last4` | HMAC-SHA256(E.164 `mobileHashSalt`) + plain last-4 |
| PAN (full) | — | never stored |
| PAN | `pan_masked` | first-3 + `****` + last-3 |

Hash salts come from **Secrets Manager**, loaded by the host service and passed to `VendorLoggerModule.forRootAsync()`.

---

## 7. Error & retry contract

- **Producer fail-open (absolute):** `logEvent()` is try/catch-wrapped; a logger error never alters or fails the
  vendor call. Ring buffer drops **oldest** when full (default 1000). Drain re-enqueues on SQS failure with
  capped exponential backoff. On hard host crash, up to the buffer's contents are lost — acceptable per NFR10.
- **Consumer:** SQS `maxReceiveCount = 5` → DLQ (14-day retention). Partial-batch failures via
  `ReportBatchItemFailures`. S3 retries are idempotent (deterministic key → new version). **ClickHouse dedup
  depends on `ReplacingMergeTree` (§3)** — until that lands, retries can create duplicate rows.

---

## 8. Metrics & dashboards — names are a contract

Library (prom-client, global `register`), prefix `vendor_api`:
- Counter **`vendor_api_calls_total`** — labels `vendor_id, endpoint, status, http_status` (`http_status` is a
  **band**: `no_response|1xx|2xx|3xx|4xx|5xx`, never a raw code — cardinality guard).
- Histogram **`vendor_api_latency_ms`** (→ series `vendor_api_latency_ms_bucket`, unit **milliseconds**),
  buckets `[50,100,200,500,1000,2000,5000]`.

**Grafana dashboards MUST use these exact names/units.** Current dashboards are wrong and must be fixed:
- `vendor_api_call_total` → `vendor_api_calls_total` (missing `s`).
- `vendor_api_latency_seconds_bucket` (×1000) → `vendor_api_latency_ms_bucket` (drop the ×1000).
- Don't hard-code vendor-id regexes in panels; use the `$vendor` template var.

The host service must expose a Prometheus `/metrics` endpoint; a Prometheus scrape + Grafana datasource
provisioning must exist (infra-later). ClickHouse-datasource panels already use correct column names.

---

## 9. Host service wiring (for adding the middleware to an API)

`VendorLoggerModule.forRootAsync()` (production pattern — loads salts before init):

| Config | Source | Rule |
|---|---|---|
| `sqsQueueUrl` | TF output `sqs_queue_url` → env `VENDOR_ARCHIVE_SQS_URL` | — |
| `sqsRegion` | **`ap-south-2`** | ⚠️ Fix the `ap-south-1` in docs/module example — the queue is in ap-south-2 |
| `serviceName` | app constant | one of the locked producer ids |
| `environment` | `NODE_ENV` | `staging`/`prod` |
| `mobileHashSalt` / `aadhaarHashSalt` | Secrets Manager | **secrets don't exist yet + service roles lack SM read** (§10) |

`main.ts` must call `app.enableShutdownHooks()` so `onModuleDestroy` drains SQS on SIGTERM.
Usage: wrap every vendor call in `vendorHttp.call(payload, fn, opts)` — never log raw responses manually.

---

## 10. Secrets & IAM (infra-later, but contracted now)

- **Only** secret provisioned today: `…/clickhouse/archiver-password` (Lambda reads it). ✅
- **Missing:** hash-salt secrets. Create `…/hash-salts/mobile` and `…/hash-salts/aadhaar`, and **grant the host
  service roles (`service_role_arns`) `secretsmanager:GetSecretValue`** on them. Today the API roles have **no**
  SM access at all — only the archiver-writer role can read `…/*`. Expose ARNs as TF outputs.
- Reconcile the empty `clickhouse_password` secret value with the CH `archiver` user password (one-time setup is
  manual per README §4 — keep it manual but documented; no plaintext in code).
- CH user is **`archiver`** (not `vendor_archive_writer` from the arch doc). INSERT-only.

---

## 11. Naming & regional conventions

- **Region: `ap-south-2` everywhere.** Any `ap-south-1` reference is a bug (library module example,
  ARCHITECTURE.html badge). CodeArtifact is the only ap-south-2 exception (D5).
- Resource prefix: `vendor-archive-{env}-…`. KMS: **one** CMK `alias/vendor-archive-{env}-vendor-archive-cmk`
  (the two-CMK `s3-cmk`/`pii-cmk` split in ARCHITECTURE.html was never built — single CMK is canonical).
- TS: camelCase identifiers; SQL/ClickHouse + SQS wire: snake_case. The boundary is the library's `toWireEvent()` (§1).

---

## 12. Coding conventions (both repos)

- No `console.log` in the **library** (ESLint-enforced) — use Nest `Logger`. The **Lambda** logs structured JSON
  to stdout and must **never** log `requestPayload`/`responsePayload` (only `requestId`, `vendorId`, `status`).
- `VENDOR_LOGGER_OPTIONS` is the single DI token — don't add more.
- Fail-open is sacred in the library; never let logging throw into the caller.
- Tests never hit real AWS — mock `SqsDrainService`, `VendorMetricsService`, SQS/S3/CH clients.
- Every change that touches the wire (§1), the mapping (§2), or the schema (§3) updates **all three together** in
  one commit, and updates this file first.

---

## 13. Resolved drift (canonical winners)

| Topic | ARCHITECTURE.html / HARDENING | **CANONICAL (this file)** |
|---|---|---|
| Wire casing | camelCase (`ARCHITECTURE.html` §05) | **snake_case wire; library maps at boundary via `toWireEvent()` (§1,§2)** |
| CH payloads | "direct"/raw | **redacted by Lambda; S3 raw (§6)** |
| ClickHouse DDL | two files | **one: `vendor-archive/clickhouse/init.sql` (§3)** |
| Engine | MergeTree (deployed) | **ReplacingMergeTree(ingested_at) (§3)** |
| KMS CMKs | two | **one CMK (§11)** |
| `async_insert` | `1` | **`0` (synchronous ack for compliance) (§2.2)** |
| DLQ retries | 3 | **5 (§7)** |
| CH user | `vendor_archive_writer` | **`archiver` (§10)** |
| Reserved concurrency | 5 | **10** |
| Region | mixed `ap-south-1/2` | **`ap-south-2` (§11)** |
| Aadhaar KMS encrypt | "Lambda encrypts" | **deferred, gated on D2; column `''` (§6)** |

---

## 14. Open decisions still gating PROD (not this iteration)

`D2` Aadhaar last-4 KMS storage pattern (Product+Compliance) · `D4` counsel sign-off on Object Lock COMPLIANCE
(Legal) · `D9` DPDP erasure vs Object Lock (Legal) · `D5` CodeArtifact vs private NPM (→ §2.3) · `D7`
compliance-officer IAM role members (CTO+Compliance). Code may land; **prod cutover is blocked on D4/D9.**
