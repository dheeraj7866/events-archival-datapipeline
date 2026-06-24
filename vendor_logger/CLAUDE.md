# vendor-logger — Project Context

## What this is

NestJS shared library that wraps every third-party vendor HTTP call with:
- Async event capture (ring buffer → SQS → Lambda → ClickHouse 90d hot + S3 forever)
- RBI compliance logging with PII redaction
- Per-vendor Prometheus metrics (Grafana dashboards)
- Correlation ID propagation via `AsyncLocalStorage`

## Architecture in one sentence

`VendorHttpService.call()` executes the vendor HTTP call, builds a `VendorApiEvent`, pushes it onto a bounded in-process `RingBuffer` (fail-open, < 1ms hot path), and a background `SqsDrainService` flushes to SQS every 100ms via `SendMessageBatch`.

## Key invariants

1. **Fail-open always** — `logEvent()` is wrapped in try/catch; a logger error must NEVER propagate to the caller or alter the vendor call result.
2. **Ring buffer drops oldest, not newest** — when full (default 1000 events), the oldest event is silently dropped. ~4 events lost on hard crash is acceptable (NFR10).
3. **S3-first ordering** — Lambda writes S3 (PutObject + Legal Hold) BEFORE ClickHouse INSERT. If ClickHouse fails, Athena on S3 provides recovery.
4. **No plaintext PII in ClickHouse or SQS** — see PII policy below.
5. **< 1ms p99 on hot path** — the `push()` to ring buffer is the only synchronous work inside the vendor call. SQS is async.

## PII field policy

| Field | Storage | Method |
|---|---|---|
| Full Aadhaar | Never stored anywhere | — |
| Aadhaar last 4 | ClickHouse `aadhaar_last4_hash` | HMAC-SHA256 (aadhaarHashSalt) |
| Aadhaar last 4 (encrypted) | ClickHouse `aadhaar_last4_encrypted` | KMS CMK — done by Lambda, not library |
| Full mobile | Never stored | — |
| Mobile hash | ClickHouse `mobile_hash` | HMAC-SHA256 E.164 normalized (mobileHashSalt) |
| Mobile last 4 | ClickHouse `mobile_last4` | plain string |
| PAN | Never stored full | — |
| PAN masked | ClickHouse `pan_masked` | first 3 + `****` + last 3 (e.g. `ABC****34F`) |
| Full account number | Never stored | — |

Hash salts come from AWS Secrets Manager. The calling service loads them at startup and passes them to `VendorLoggerModule.forRoot()`.

## Loan lifecycle stages (D1 — locked)

```
LEAD → SELFIE → KYC → PAN_AADHAAR_SEED → LOCATION_BRE → BUREAU_BRE →
BANK_BRE → REPEAT_BRE → UNDERWRITING → DISBURSED →
REPAID | OVERDUE | CLOSED | WRITTEN_OFF
```

## 5-state status model

| Status | Trigger |
|---|---|
| `SUCCESS` | HTTP 2xx from vendor fn return |
| `FAILURE` | HTTP 4xx/5xx OR fn throws a non-network/non-timeout error |
| `TIMEOUT` | `ECONNABORTED`, `ETIMEDOUT`, message contains "timeout" |
| `NETWORK_ERROR` | `ECONNREFUSED`, `ENOTFOUND`, `ECONNRESET`, `EHOSTUNREACH`, `ENETUNREACH` |
| `LOGGER_ERROR` | Used in metrics only — when the logger itself fails |

## Module registration (host service)

```typescript
// app.module.ts
import { VendorLoggerModule } from 'vendor-logger';

@Module({
  imports: [
    VendorLoggerModule.forRoot({
      sqsQueueUrl: process.env.VENDOR_ARCHIVE_SQS_URL,
      sqsRegion: 'ap-south-1',
      serviceName: 'identity-api',
      environment: process.env.NODE_ENV,
      mobileHashSalt: secretsManagerSecrets.mobileHashSalt,
      aadhaarHashSalt: secretsManagerSecrets.aadhaarHashSalt,
    }),
  ],
})
export class AppModule implements NestModule {
  configure(consumer: MiddlewareConsumer): void {
    consumer.apply(CorrelationMiddleware).forRoutes('*');
  }
}
```

## VendorHttpService.call() usage

```typescript
const result = await this.vendorHttp.call(
  { pan, name, dob },                   // request payload (logged)
  async (req) => {
    const res = await this.http.post('/kyc/verify', req).toPromise();
    return { data: res.data, httpStatus: res.status };
  },
  {
    vendorId: 'karza',
    endpoint: '/kyc/verify',
    loanLifecycleStage: LoanLifecycleStage.KYC,
    applicationId: application.id,
    pan: req.pan,
    mobile: req.mobile,
    costPaise: 150,
  },
);
```

The `fn` callback is responsible for the actual HTTP call. `call()` handles timing, PII redaction, event building, and async enqueue.

## Coding conventions

- All new vendor integrations MUST use `VendorHttpService.call()` — never log raw responses manually
- Never add `console.log` — use NestJS `Logger` service; the ESLint rule enforces this
- Payload fields that contain PII should be sanitized at the source before passing to `requestPayload`. The library does NOT deep-scan payloads for PII.
- If a vendor returns Aadhaar data in the response body, strip it before returning from the `fn` callback
- `VENDOR_LOGGER_OPTIONS` token is the single config injection point — do not add more injection tokens

## Testing conventions

- Unit tests mock `SqsDrainService` and `VendorMetricsService` — never make real SQS/AWS calls in tests
- Use `CorrelationContext.run()` to simulate correlation ID propagation in tests
- Test fail-open by making `drainEnqueue` throw and asserting the vendor result still returns
- Real-world test file: `test/real-world-scenarios.spec.ts` — use actual vendor ID strings (karza, easebuzz, nsdl, bank-statement-analyser)

## Open decisions (as of 2026-05-29)

| ID | Decision | Status |
|---|---|---|
| D2 | ClickHouse HA: single vs replicated MergeTree | Pending |
| D3 | S3 cross-region replication target region | Pending |
| D4 | Compliance counsel sign-off on S3 Object Lock COMPLIANCE indefinite | Pending |
| D5 | CodeArtifact vs private NPM registry | Pending |
| D6 | BFF frontend for log search (Phase 2) | Deferred |
| D7 | compliance-officer IAM role for Legal Hold removal | Pending |
| D8 | Athena query patterns for RBI audit response | Deferred |
| D9 | DPDP erasure vs Object Lock conflict — counsel required | Pending |

## File structure

```
src/
  types/             VendorApiEvent, enums, module options
  correlation/       AsyncLocalStorage context + NestJS middleware
  pii/               HMAC-SHA256 hashing, PAN masking
  queue/             RingBuffer + SqsDrainService
  metrics/           Prometheus Counter + Histogram
  http/              VendorHttpService (the main consumer API)
  vendor-logger.module.ts
  index.ts
test/
  pii-redactor.spec.ts
  ring-buffer.spec.ts
  vendor-http.spec.ts
  real-world-scenarios.spec.ts
```
