/**
 * ─── SHARED CONTRACT — DO NOT EDIT FREEHAND ──────────────────────────────────
 * Mirror of vendor-logger `src/types/vendor-event.wire.ts`.
 * This is the snake_case wire shape the library puts onto SQS (CONVENTIONS.md §1) —
 * 1:1 with the ClickHouse columns the producer owns. Lambda-added columns
 * (ingested_at, s3_*_key, aadhaar_last4_encrypted) are NOT on the wire.
 * The library is the source of truth; keep in sync (D5 / CONVENTIONS.md §2.3).
 * ─────────────────────────────────────────────────────────────────────────────
 */

export enum LoanLifecycleStage {
  LEAD = 'LEAD',
  SELFIE = 'SELFIE',
  KYC = 'KYC',
  PAN_AADHAAR_SEED = 'PAN_AADHAAR_SEED',
  LOCATION_BRE = 'LOCATION_BRE',
  BUREAU_BRE = 'BUREAU_BRE',
  BANK_BRE = 'BANK_BRE',
  REPEAT_BRE = 'REPEAT_BRE',
  UNDERWRITING = 'UNDERWRITING',
  DISBURSED = 'DISBURSED',
  REPAID = 'REPAID',
  OVERDUE = 'OVERDUE',
  CLOSED = 'CLOSED',
  WRITTEN_OFF = 'WRITTEN_OFF',
  LMS_QUERY = 'LMS_QUERY',
  PENNY_DROP = 'PENNY_DROP',
  LOAN_AGREEMENT = 'LOAN_AGREEMENT',
  DISBURSEMENT = 'DISBURSEMENT',
}

export enum VendorStatus {
  SUCCESS = 'SUCCESS',
  FAILURE = 'FAILURE',
  TIMEOUT = 'TIMEOUT',
  NETWORK_ERROR = 'NETWORK_ERROR',
  LOGGER_ERROR = 'LOGGER_ERROR',
}

/**
 * The exact JSON shape the library serializes onto SQS — snake_case.
 * `request_payload` / `response_payload` are JSON-stringified STRINGS on the wire
 * (may end with `...[TRUNCATED]` or be the literal `[OVERSIZED]`).
 */
export interface VendorApiEventWire {
  schema_version: number;
  request_id: string;
  created_at: string;
  service: string;
  environment: string;
  vendor_id: string;
  endpoint: string;
  vendor_ref_id?: string;
  loan_lifecycle_stage: string;
  loan_application_number?: string;
  user_id?: string;
  pan_masked?: string;
  mobile_hash?: string;
  mobile_last4?: string;
  aadhaar_last4_hash?: string;
  consent_id?: string;
  status: string;
  http_status: number;
  latency_ms: number;
  error_code?: string;
  error_message?: string;
  request_payload: string;
  response_payload: string;
  payload_truncated: boolean;
  request_hash: string;
}
