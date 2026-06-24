# Integration Completion Plan — Vendor API Archiving

**Goal:** Make `@finagle/vendor-logger` → SQS → Lambda → S3 + ClickHouse → Grafana work end-to-end, with tests,
so we can start adding the middleware to the API codebases (`identity-api`, `los-api`, `payment-api`).

**Scope this iteration:** **Code + contracts + tests only.** Terraform `apply`, secret values, and ClickHouse
provisioning are **infra-later** (documented in Phase 5, not executed here).
**Contract authority:** [CONVENTIONS.md](CONVENTIONS.md). Update it *before* code when the contract moves.
**Decisions locked:** redaction **Lambda (S3 raw / CH redacted)**; scope **code-only**.

> **Update 2026-05-29 — wire casing reversed to snake_case.** Originally we kept the camelCase wire and mapped in
> the Lambda (Phases 0–1 below reflect that). We then switched to the **cleaner contract**: the SQS wire is now
> **snake_case** (1:1 with ClickHouse columns), produced by the library's `toWireEvent()` at the SQS boundary; the
> Lambda no longer renames fields (passthrough + added cols + redaction). Done while there were zero live
> producers/consumers. Both suites green (16 Lambda, 107 library). See [CONVENTIONS §1–2](CONVENTIONS.md).

Legend: ☐ todo · ◐ in progress · ☑ done · ⏸ infra-later/blocked

---

## Phase 0 — Foundations (no behavior change) ✅
- ☑ Author [CONVENTIONS.md](CONVENTIONS.md) (canonical contract)
- ☑ Author this plan
- ☑ Mark `finagle_vendor_logger/clickhouse/001_vendor_api_events.sql` as `-- DEPRECATED` (point to canonical)
- ☑ Set up the Lambda shared-contract path (§2.3): vendored mirror `lambda/vendor-archiver/src/contract/`
  (`VendorApiEvent` + `PayloadRedactor`) with header comment. *(Target: CodeArtifact import, D5. Build-sync step still TODO — see follow-ups.)*

## Phase 1 — Lambda deserialization fix 🔴 PIPELINE BLOCKER  *(audit dim 1, 2)* ✅
File: [`vendor-archive/lambda/vendor-archiver/src/index.ts`](vendor-archive/lambda/vendor-archiver/src/index.ts)
- ☑ Replace the snake_case `VendorEvent` interface with the camelCase `VendorApiEvent` (from shared contract)
- ☑ Map camelCase → snake_case per [CONVENTIONS §2.1](CONVENTIONS.md) (`mapToClickHouseRow`)
- ☑ Stop re-`JSON.stringify`-ing payloads — S3 stores raw, CH stores redacted (Phase 3)
- ☑ Populate `environment`, `error_message`, `request_hash` into the row
- ☑ Keep `aadhaar_last4_encrypted = ''` (deferred, D2) — not fabricated
- ☑ Guard `created_at`/`s3Key` against bad input (`safeYmd` — no crash)
- ☑ Sanitize `endpoint` in the S3 key (`sanitizeEndpoint`) — [CONVENTIONS §5](CONVENTIONS.md)
- ☑ Drop the redundant `PutObjectLegalHold` call (SCP conflict); hold set inline on PutObject

## Phase 2 — ClickHouse schema reconciliation  *(audit dim 3, 6)*  ✅ (file edited; ⏸ apply infra-later)
File: [`vendor-archive/clickhouse/init.sql`](vendor-archive/clickhouse/init.sql)
- ☑ Add columns `environment`, `error_message`, `request_hash` (defaults `''`)
- ☑ Switch engine to `ReplacingMergeTree(ingested_at)`, `request_id` in `ORDER BY` (dedup, P2-5)
- ☑ Reconcile `loan_lifecycle_stage`/`status` comments to the locked enums ([CONVENTIONS §4](CONVENTIONS.md))
- ☑ Lambda `ClickHouseRow` is column-for-column identical (asserted by mapping test)

## Phase 3 — Payload redaction wiring  *(audit dim 2)* ✅
- ☑ Lambda applies `PayloadRedactor.redact()` to req/resp **before** CH INSERT (`redactForClickHouse`)
- ☑ S3 receives **raw** payloads (verified by handler test gunzip assertion)
- ☑ Fail-closed: unparseable (truncated/[OVERSIZED]) payloads → `[REDACTED:UNPARSEABLE]` in CH ([CONVENTIONS §6](CONVENTIONS.md))
- ☑ Negative tests: PAN/Aadhaar/mobile masked in CH row, raw PAN intact in S3 body

## Phase 4 — Grafana / metrics contract  *(audit dim 7, 8)* ✅
Files: `vendor-archive/grafana/dashboards/*.json`, `grafana/alertmanager/rules.yaml`
- ☑ `vendor_api_call_total` → `vendor_api_calls_total` (all panels + rules.yaml)
- ☑ `vendor_api_latency_seconds_bucket` → `vendor_api_latency_ms_bucket`; dropped the `×1000`
- ☐ Replace hard-coded vendor-id regexes with the `$vendor` template var *(deferred — panels flagged below)*
- ☑ Cross-checked alertmanager `rules.yaml` for the same metric-name drift
- ☐ Host `/metrics` exposure + Grafana datasource provisioning → Phase 5 (infra-later)

### Phase 4 follow-up — hard-coded vendor lists to template (`$vendor`)
- `vendor-failure-rate.json` panel id 3 (`easebuzz|synoriq|icici-bank|internal-bre`), id 4 (`digitap|signzy`), id 5 (ClickHouse `IN(...)`)
- `rules.yaml` P1/P2 alert vendor regexes

## Phase 5 — Infra-later (documented, NOT executed this iteration) ⏸
- ⏸ Create Secrets Manager `…/hash-salts/mobile` + `…/hash-salts/aadhaar`; grant `service_role_arns` SM read; output ARNs ([CONVENTIONS §10](CONVENTIONS.md))
- ⏸ Run the reconciled `init.sql`; reconcile `archiver` password with the SM secret (README §4 one-time setup)
- ⏸ Fix `sqsRegion` `ap-south-1`→`ap-south-2` in the library module example + ARCHITECTURE badge
- ⏸ Stand up Prometheus scrape + Grafana ClickHouse/Prometheus datasource provisioning
- ⏸ Decide D5 (CodeArtifact) to replace the vendored contract mirror with a package import
- ⏸ Resolve SCP vs `PutObjectLegalHold` for the archiver role
- ⏸ `terraform plan/apply` (staging) — gated; prod blocked on D4/D9

## Phase 6 — Tests & verification  *(makes "green" provable)* ✅
Files: `lambda/vendor-archiver/{jest.config.js,test/*}`
- ☑ Lambda unit tests: camelCase event → exact `ClickHouseRow`; null/missing-field handling; unparseable-payload fail-closed; bad `created_at`; endpoint sanitization (`test/mapping.test.ts`)
- ☑ Contract test: full + minimal `VendorApiEvent` map with **zero** undefined columns + no camelCase leakage — pins the casing contract
- ☑ Handler end-to-end (mocked S3/SM/CH): asserts S3 body holds **raw** PAN, CH row is **redacted** snake_case, poison-pill isolation, whole-batch retry on CH failure (`test/handler.test.ts`)
- ☑ Lambda: 16 tests pass · `tsc --noEmit` clean
- ☑ Library suite still green (**107** tests — doc's "50" was stale)
- ☐ Update `ARCHITECTURE.html` §05 mapping table + `HARDENING_PLAN.md` to match CONVENTIONS (kill drift at source) *(follow-up)*

---

## Findings from dev smoke test (2026-05-30)
- ☑ **FIXED (stopgap) — SG inline+standalone conflict re-broke connectivity on `plan`:** the clickhouse module SG uses inline `ingress {}` blocks while the env adds standalone `aws_security_group_rule` (to break the cycle). The SG tried to revoke the standalone Lambda 8123/9000 rules on every apply. Added `lifecycle { ignore_changes = [ingress] }` so they coexist. **Proper follow-up:** move ALL CH SG rules to standalone resources and drop inline blocks (also fixes the prod SG cycle).
- ☑ **FIXED — archiver INSERT-only blocked the materialized view:** `vendor_failure_counts_mv` runs its SELECT as the inserting user, so `archiver` (INSERT-only) hit `ACCESS_DENIED` (code 497) on every insert. Added column-scoped `GRANT SELECT(created_at,vendor_id,endpoint,service,status,latency_ms)` (no PII columns) to init.sql.
- ☑ **FIXED — CH SG had no Lambda ingress on 8123/9000:** the cycle-break standalone `aws_security_group_rule`s weren't applied (changes had been imperatively patched). A full `terraform apply` created them; both directions now open.
- ☑ **FIXED — Lambda → ClickHouse used wrong port:** `@clickhouse/client` speaks **HTTP (8123)** but `CLICKHOUSE_PORT` was **9000** (native) → `ECONNREFUSED`. Set `clickhouse_port = 8123` (lambda var default + staging/prod tfvars).
- ☑ **FIXED — ClickHouse only listened on localhost:** `user_data` never set `listen_host`, so CH bound to 127.0.0.1 → Lambda (private IP) got `ECONNREFUSED`. Added `config.d/listen.xml` (`<listen_host>0.0.0.0</listen_host>`) to user_data (SG still gates access).
- ☑ **FIXED — archiver secret was empty:** `clickhouse_password` secret had no version (no `AWSCURRENT`) → `getClickHouseClient` threw `ResourceNotFoundException`. Set value + matching CH user pw (manual on box; automated for future instances via the user_data bootstrap).
- ☑ **FIXED — Lambda couldn't receive from the SSE-KMS queue:** the `archiver-writer` role had KMS Encrypt/GenerateDataKey/DescribeKey but **no `kms:Decrypt`**. SQS queue is SSE-KMS, so the Lambda poller couldn't decrypt messages → 0 invocations, no logs, message dead-lettered. Added `kms:Decrypt` to the role (safe: role has no `s3:GetObject`, so the S3 archive stays unreadable). CMK key policy already delegates to IAM (`EnableIAMPolicies`), so no kms-module change needed.
- ☑ **FIXED — `user_data` exceeded 16KB:** inlined `init.sql` + double base64 (`base64encode` into the plaintext `user_data` arg). Switched to `user_data_base64`; `ignore_changes` updated.

## Findings from local test pass (2026-05-29)
- ☑ **FIXED — library build emitted no JS:** `tsconfig.build.json` had no `include`; with the inherited `"files": []` it compiled nothing. Added `"include": ["src/**/*"]`. (The Lambda can't import a library that never builds.)
- ☐ **Lambda bundle packs devDeps:** `npm run bundle` zips all of `node_modules` (13,151 entries incl jest/typescript/eslint → 21 MB). Should `npm ci --omit=dev` before zipping (and `@aws-sdk/*` is provided by the Lambda runtime — excludable). Real packaging fix for the deploy iteration.
- ☐ **PROD terraform dependency cycle (blocker):** `environments/prod/main.tf` uses inline `allowed_ingress_sg_ids = [module.lambda.lambda_sg_id]` while `clickhouse_sg_id = module.clickhouse.security_group_id` → cycle; `terraform validate` fails. **Staging already fixed it** (`allowed_ingress_sg_ids = []` + standalone `aws_security_group_rule`). Mirror the staging pattern in prod.
- ☐ **`terraform fmt`:** 5 files unformatted (prod tfvars, staging main.tf, clickhouse/codeartifact/lambda module main.tf) — cosmetic.

### Local test pass — green
- library **107/107** · Lambda **16/16** · cross-repo contract **5/5** ([test/cross-repo-contract.test.js](test/cross-repo-contract.test.js)) · staging `terraform validate` ✅

## Follow-ups opened during implementation
- **Library P0-1:** extend `PayloadRedactor` to scan *embedded* PAN/mobile/email (today only Aadhaar is global), so truncated payloads can be stored redacted in CH instead of `[REDACTED:UNPARSEABLE]` ([CONVENTIONS §6](CONVENTIONS.md)).
- **Contract sync:** add a build step that copies the library's `vendor-event.types.ts` + `payload-redactor.ts` into `lambda/vendor-archiver/src/contract/` (or replace with a CodeArtifact import once D5 lands) so the mirror can't silently drift.
- **Docs:** reconcile `ARCHITECTURE.html` §05 / `HARDENING_PLAN.md` to CONVENTIONS (async_insert, DLQ count, CH user, region, single CMK).
- **Grafana:** template the hard-coded vendor lists (Phase 4 follow-up above).

---

## Audit-dimension → phase traceability
| Audit dimension | Phase(s) |
|---|---|
| 1 SQS schema | 1, 6 |
| 2 PII handoff | 1, 3 |
| 3 ClickHouse schema | 2 |
| 4 Secrets Manager | 5 (infra-later) |
| 5 Module config wiring | 5 + CONVENTIONS §9 |
| 6 Error/retry/dedup | 1, 2 |
| 7 Status/enum/metrics | 2, 4 |
| 8 Missing glue | 1–4 built; 5 infra-later |

## Definition of done (this iteration)
Lambda maps a real library event with no undefined columns · CH gets redacted snake_case rows, S3 gets raw ·
schema file + dashboards reconciled · contract test pins casing · library suite green · CONVENTIONS is the
single source of truth and ARCHITECTURE/HARDENING no longer contradict it. Infra apply + prod = next iteration.

## Parallelizable workstreams
Independent once Phase 0 lands: **A** Phase 1+3 (Lambda) · **B** Phase 2 (schema) · **C** Phase 4 (Grafana) ·
**D** Phase 6 test harness scaffolding. A and B must land together before the Phase 6 end-to-end test.
