import { VendorApiEvent } from './vendor-event.types';

/**
 * The canonical SQS wire contract — snake_case, 1:1 with the ClickHouse columns the
 * producer is responsible for (see CONVENTIONS.md §1). The library keeps `VendorApiEvent`
 * in camelCase for TypeScript ergonomics and maps to this shape at the SQS boundary only.
 *
 * Lambda-added columns (ingested_at, s3_request_key, s3_response_key,
 * aadhaar_last4_encrypted) are intentionally NOT part of the wire.
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

/** Map the internal camelCase event to the snake_case wire contract. */
export function toWireEvent(e: VendorApiEvent): VendorApiEventWire {
  return {
    schema_version: e.schemaVersion,
    request_id: e.requestId,
    created_at: e.createdAt,
    service: e.service,
    environment: e.environment,
    vendor_id: e.vendorId,
    endpoint: e.endpoint,
    vendor_ref_id: e.vendorRefId,
    loan_lifecycle_stage: e.loanLifecycleStage,
    loan_application_number: e.loanApplicationNumber,
    user_id: e.userId,
    pan_masked: e.panMasked,
    mobile_hash: e.mobileHash,
    mobile_last4: e.mobileLast4,
    aadhaar_last4_hash: e.aadhaarLast4Hash,
    consent_id: e.consentId,
    status: e.status,
    http_status: e.httpStatus,
    latency_ms: e.latencyMs,
    error_code: e.errorCode,
    error_message: e.errorMessage,
    request_payload: e.requestPayload,
    response_payload: e.responsePayload,
    payload_truncated: e.payloadTruncated,
    request_hash: e.requestHash,
  };
}
