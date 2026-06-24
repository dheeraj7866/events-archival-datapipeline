import {
  VendorApiEventWire,
  LoanLifecycleStage,
  VendorStatus,
} from "../src/contract/vendor-event.types";

/** A realistic, fully-populated snake_case wire event as the library puts on SQS. */
export function fullEvent(
  overrides: Partial<VendorApiEventWire> = {}
): VendorApiEventWire {
  return {
    schema_version: 1,
    request_id: "11111111-2222-3333-4444-555555555555",
    created_at: "2026-05-29T08:30:00.000Z",
    service: "identity-api",
    environment: "staging",
    vendor_id: "karza",
    endpoint: "/kyc/verify",
    vendor_ref_id: "karza-txn-999",
    loan_lifecycle_stage: LoanLifecycleStage.KYC,
    loan_application_number: "LAN-2026-0001",
    user_id: "user-555",
    pan_masked: "ABC****34F",
    mobile_hash: "deadbeefcafe",
    mobile_last4: "3210",
    aadhaar_last4_hash: "feedface1234",
    consent_id: "consent-42",
    status: VendorStatus.SUCCESS,
    http_status: 200,
    latency_ms: 142,
    error_code: undefined,
    error_message: undefined,
    // Raw PII inside the payloads — must be masked in ClickHouse, raw in S3.
    request_payload: JSON.stringify({
      pan: "ABCDE1234F",
      mobile: "9876543210",
      email: "rakesh@gmail.com",
      name: "Rakesh Kumar",
    }),
    response_payload: JSON.stringify({
      status: "VALID",
      nameMatch: true,
      aadhaar: "1234 5678 9012",
    }),
    payload_truncated: false,
    request_hash:
      "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    ...overrides,
  };
}

/** The minimal event: only required fields set, all optionals omitted. */
export function minimalEvent(): VendorApiEventWire {
  return {
    schema_version: 1,
    request_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    created_at: "2026-05-29T08:30:00.000Z",
    service: "los-api",
    environment: "staging",
    vendor_id: "crif",
    endpoint: "bureau-pull",
    loan_lifecycle_stage: LoanLifecycleStage.BUREAU_BRE,
    status: VendorStatus.FAILURE,
    http_status: 0,
    latency_ms: 30000,
    request_payload: "{}",
    response_payload: "null",
    payload_truncated: false,
    request_hash: "abc",
  };
}
