# Integration — wiring `vendor-logger` into the API services

**Status:** staging pipeline GREEN (e2e verified 2026-05-31). This is the actual goal the
infra exists to serve. See [CONVENTIONS.md](CONVENTIONS.md) for the contract, [STATUS.md](STATUS.md)
for where we stand, [EMERGENCY.md](vendor-archive-infra/EMERGENCY.md) for the ops runbook.

---

## 1. The goal

Add the shared library to each NestJS service (`identity-api` → `los-api` → `payment-api`) so every
third-party vendor HTTP call is captured and archived, with **zero** change to fail behavior (fail-open).
Roll out **one low-volume endpoint first**, confirm it lands in ClickHouse + S3, then expand.

```
identity-api / los-api / payment-api
      │  vendorHttp.call(payload, fn, opts)     ← the only code change per call site
      ▼
  vendor-logger  → snake_case wire → SQS → Lambda → S3 (raw) + ClickHouse (redacted)
```

## 2. Host wiring (per service)

`app.module.ts` — use `forRootAsync` so hash salts load from Secrets Manager before init:
```ts
VendorLoggerModule.forRootAsync({
  global: true,
  inject: [SecretsService],
  useFactory: async (sm) => ({
    sqsQueueUrl: process.env.VENDOR_ARCHIVE_SQS_URL!,
    sqsRegion: 'ap-south-2',                 // NOT ap-south-1 — the queue is in ap-south-2
    serviceName: 'identity-api',             // one of the locked producer ids
    environment: process.env.NODE_ENV!,      // staging | prod
    mobileHashSalt:  await sm.get('MOBILE_HASH_SALT'),
    aadhaarHashSalt: await sm.get('AADHAAR_HASH_SALT'),
  }),
})
```
`main.ts` — `app.enableShutdownHooks();` so the ring buffer drains to SQS on SIGTERM.

Wrap one vendor call:
```ts
const res = await this.vendorHttp.call(
  reqPayload,
  async (req) => { const r = await this.http.post('/kyc/verify', req).toPromise();
                   return { data: r.data, httpStatus: r.status }; },
  { vendorId: 'karza', endpoint: '/kyc/verify', loanLifecycleStage: LoanLifecycleStage.KYC,
    applicationId, pan, mobile, costPaise: 150 },
);
```

## 3. Infra prerequisites that DON'T exist yet (must build before the library can send)

| # | Item | Where |
|---|---|---|
| P1 | Secrets Manager secrets `…/hash-salts/mobile` + `…/hash-salts/aadhaar` | new TF in the secrets/lambda area |
| P2 | Host service IAM role: `sqs:SendMessage` on the queue **+** `secretsmanager:GetSecretValue` on the salts | the queue policy already allows `service_role_arns` to send — just add the API's role ARN to `service_role_arns` (currently `[]` in `staging.tfvars`) and grant it SM read on the salts |
| P3 | Host env `VENDOR_ARCHIVE_SQS_URL` = `terraform output sqs_queue_url` | service deploy config |

Until P1–P2 exist, the library **cannot boot** (no salts) or **cannot send** (no SQS perms). These are the
§9/§10 gaps in CONVENTIONS.

## 4. Verify a real (non-synthetic) event lands

Same tooling proven during bring-up ([vendor-archive-infra/scripts/verify-smoke.sh](vendor-archive-infra/scripts/verify-smoke.sh)):
- find the row by `correlation_id` in ClickHouse → confirm masked PII (`pan_masked`, redacted payload)
- confirm the S3 object exists (raw payload)
- DLQ stays 0

This proves the **library itself** (not a hand-crafted message) emits a valid wire event and the HMAC/masking
all work in situ.

## 5. Rollout order

1. `identity-api` — one Karza/KYC endpoint → watch a day → expand to its other vendors (NSDL, Digitap).
2. `los-api` — CRIF / Equifax / BSA.
3. `payment-api` — Easebuzz.

Standard queue + Lambda scale with the fan-in; watch the SQS depth + DLQ alarms as volume grows.

---

## 6. Bring-up issues & WHERE each fix lives (so a fresh provision is correct)

During staging bring-up the pipeline failed at **7 successive layers** (each only visible once the prior was
fixed, because the Lambda fails fast and retries the whole batch). All are now fixed **in code** except the
secret *value* (intentionally not in code). This table answers "is it in code / user_data / terraform / manual?"

| # | Symptom | Root cause | Fix — and where it lives | Type |
|---|---|---|---|---|
| 1 | poller never invoked Lambda; msg → DLQ, 0 invocations | `archiver-writer` role lacked `kms:Decrypt`; SQS queue is SSE-KMS so the poller couldn't decrypt | `terraform/modules/iam/main.tf` — added `kms:Decrypt` to the role | **code (TF)** — `apply` |
| 2 | `ResourceNotFoundException ... AWSCURRENT` in `getClickHouseClient` | CH password secret had no value (no `secret_version` in TF) | secret **value** set via `put-secret-value`; fresh instances self-set it in `user_data` bootstrap | **runtime** (value never in code, by design) + user_data automates future |
| 3 | `Port 9000 is for clickhouse-client ... use 8123` | `@clickhouse/client` is HTTP; `CLICKHOUSE_PORT` was native `9000` | `terraform/modules/lambda/variables.tf` default + `*/terraform.tfvars` → `8123` | **code (TF)** — `apply` |
| 4 | `ECONNREFUSED 10.20.x:8123` then worked-on-box-only | ClickHouse bound to `127.0.0.1` (no `listen_host`) | `terraform/modules/clickhouse/user_data.sh.tpl` — writes `config.d/listen.xml` (`0.0.0.0`) | **code (user_data)** — current box fixed manually; future instances automatic |
| 5 | `ETIMEDOUT 8123` (9000 worked) | CH SG had no `8123` ingress from the Lambda SG | the standalone `aws_security_group_rule` in `environments/staging/main.tf` — needed a real `terraform apply` (had been env-patched) | **code (TF)** — `apply` |
| 6 | `terraform plan` wanted to REMOVE the working Lambda ingress | SG mixes inline `ingress{}` blocks with standalone `aws_security_group_rule` (Terraform anti-pattern) — they fight | `terraform/modules/clickhouse/main.tf` — `lifecycle { ignore_changes = [ingress] }` (stopgap) | **code (TF)**; proper fix = all-standalone rules (follow-up, also fixes prod SG cycle) |
| 7 | `ACCESS_DENIED (497) ... while pushing to view vendor_failure_counts_mv` | `archiver` was INSERT-only; the MV runs its SELECT+INSERT as the inserting user | `clickhouse/init.sql` — `GRANT SELECT(6 cols)` on the table + `GRANT INSERT` on `vendor_failure_counts_1m` | **code (init.sql)** — current box granted manually; future runs via init.sql in user_data |

Adjacent fixes from the same effort:
| Symptom | Fix — where | Type |
|---|---|---|
| `user_data` > 16 KB on apply | `clickhouse/main.tf` — `user_data_base64` (not double-encoded `user_data`) + `ignore_changes=[user_data_base64]` | code (TF) |
| library `npm run build` emitted no JS | `vendor_logger/tsconfig.build.json` — add `"include": ["src/**/*"]` | code |
| Lambda zip bundles devDeps (21 MB) | `npm ci --omit=dev` before zip (and `@aws-sdk/*` is in the runtime) | **follow-up — not yet fixed** |

### The meta-lesson
Several fixes were first applied **imperatively** (env patches, manual secret/grant/listen.xml, partial applies),
which made the live infra **drift** from code — that's why `terraform plan` kept surprising us. Going forward:
treat `terraform plan` as truth, and ensure every runtime fix is also in code so a fresh provision reproduces it.
After bring-up, a clean `terraform plan` (no changes) is the sign code = reality.

### Still-open follow-ups (tracked in [plan.md](plan.md))
- Move CH SG rules fully to standalone (drop inline) → removes the `ignore_changes` stopgap **and** fixes the prod SG cycle (prod won't `validate` until then).
- Lambda bundle: prod-deps only.
- Hash-salt secrets + host-role SM grant (P1/P2 above) — needed before any API integration.
- Library P0-1: redactor embedded PAN/mobile scan (today truncated payloads store `[REDACTED:UNPARSEABLE]`).
- D2/D4/D9 (counsel/product) still gate **prod**.
