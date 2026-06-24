import {
  mapToClickHouseRow,
  redactForClickHouse,
  safeYmd,
  sanitizeEndpoint,
  s3Key,
  ClickHouseRow,
} from "../src/index";
import { fullEvent, minimalEvent } from "./fixtures";

describe("mapToClickHouseRow — the camelCase→snake_case contract (CONVENTIONS §2.1)", () => {
  const INGESTED = "2026-05-29T08:30:01.500Z";

  it("maps every field of a full event with no undefined columns", () => {
    const row = mapToClickHouseRow(fullEvent(), INGESTED, "req/key", "resp/key");

    // The contract: not a single column may be undefined (would break JSONEachRow).
    for (const [col, val] of Object.entries(row)) {
      expect(val !== undefined).toBe(true);
    }

    expect(row).toMatchObject<Partial<ClickHouseRow>>({
      schema_version: 1,
      request_id: "11111111-2222-3333-4444-555555555555",
      created_at: "2026-05-29T08:30:00.000Z",
      ingested_at: INGESTED,
      service: "identity-api",
      environment: "staging",
      vendor_id: "karza",
      endpoint: "/kyc/verify",
      vendor_ref_id: "karza-txn-999",
      loan_lifecycle_stage: "KYC",
      loan_application_number: "LAN-2026-0001",
      user_id: "user-555",
      pan_masked: "ABC****34F",
      mobile_hash: "deadbeefcafe",
      mobile_last4: "3210",
      aadhaar_last4_hash: "feedface1234",
      aadhaar_last4_encrypted: "", // DEFERRED (D2) — never fabricated
      consent_id: "consent-42",
      status: "SUCCESS",
      http_status: 200,
      latency_ms: 142,
      s3_request_key: "req/key",
      s3_response_key: "resp/key",
      payload_truncated: 0,
      request_hash:
        "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    });
  });

  it("defaults all optional fields safely on a minimal event", () => {
    const row = mapToClickHouseRow(minimalEvent(), INGESTED, "r", "s");

    expect(row.vendor_ref_id).toBe("");
    expect(row.user_id).toBe("");
    expect(row.pan_masked).toBe("");
    expect(row.mobile_hash).toBe("");
    expect(row.aadhaar_last4_hash).toBe("");
    expect(row.aadhaar_last4_encrypted).toBe("");
    expect(row.consent_id).toBe("");
    expect(row.error_code).toBe("");
    expect(row.error_message).toBe("");
    expect(row.http_status).toBe(0);
    expect(row.schema_version).toBe(1);
    expect(row.loan_application_number).toBeNull(); // absent → null, not undefined
    for (const val of Object.values(row)) expect(val !== undefined).toBe(true);
  });

  it("redacts PII in the ClickHouse payload copy", () => {
    const row = mapToClickHouseRow(fullEvent(), INGESTED, "r", "s");
    // raw PAN / mobile / aadhaar must NOT survive into the queryable tier
    expect(row.request_payload).not.toContain("ABCDE1234F");
    expect(row.request_payload).not.toContain("9876543210");
    expect(row.request_payload).toContain("ABC****34F"); // masked PAN present
    expect(row.response_payload).not.toContain("1234 5678 9012");
    expect(row.response_payload).toContain("[AADHAAR_REDACTED]");
  });
});

describe("redactForClickHouse — fail-closed on non-JSON payloads (§6)", () => {
  it("redacts valid-JSON payloads structurally", () => {
    const out = redactForClickHouse(JSON.stringify({ pan: "ABCDE1234F" }));
    expect(out).not.toContain("ABCDE1234F");
    expect(out).toContain("ABC****34F");
  });

  it("replaces an [OVERSIZED] payload with a safe placeholder", () => {
    expect(redactForClickHouse("[OVERSIZED]")).toBe("[REDACTED:UNPARSEABLE]");
  });

  it("never leaks PII from a truncated (invalid JSON) payload", () => {
    const truncated = '{"pan":"ABCDE1234F","name":"Rak...[TRUNCATED]';
    const out = redactForClickHouse(truncated);
    expect(out).toBe("[REDACTED:UNPARSEABLE]");
    expect(out).not.toContain("ABCDE1234F");
  });
});

describe("safeYmd — never throws on bad createdAt", () => {
  it("uses createdAt when valid", () => {
    expect(safeYmd("2026-05-29T08:30:00.000Z", "2020-01-01T00:00:00Z")).toBe(
      "2026/05/29"
    );
  });
  it("falls back when createdAt is invalid", () => {
    expect(safeYmd("not-a-date", "2026-05-29T00:00:00.000Z")).toBe("2026/05/29");
  });
  it("falls back when createdAt is empty", () => {
    expect(safeYmd("", "2026-05-29T00:00:00.000Z")).toBe("2026/05/29");
  });
});

describe("sanitizeEndpoint — no extra S3 path segments (§5)", () => {
  it("strips leading slash and flattens inner slashes", () => {
    expect(sanitizeEndpoint("/kyc/verify")).toBe("kyc_verify");
  });
  it("handles already-clean endpoints", () => {
    expect(sanitizeEndpoint("bureau-pull")).toBe("bureau-pull");
  });
  it("falls back to 'unknown' for empty input", () => {
    expect(sanitizeEndpoint("")).toBe("unknown");
  });
});

describe("s3Key — deterministic, partitioned layout", () => {
  it("includes the user_id folder between endpoint and request_id", () => {
    // YYYY/MM/DD/{vendor}/{endpoint}/{user_id}/{request_id}/{type}.json.gz
    expect(s3Key(fullEvent(), "request")).toBe(
      "2026/05/29/karza/kyc_verify/user-555/11111111-2222-3333-4444-555555555555/request.json.gz"
    );
  });
  it("falls back to 'unknown' when user_id is absent", () => {
    const e = fullEvent();
    delete (e as any).user_id;
    expect(s3Key(e, "response")).toBe(
      "2026/05/29/karza/kyc_verify/unknown/11111111-2222-3333-4444-555555555555/response.json.gz"
    );
  });
  it("falls back to 'unknown' when user_id is an empty string", () => {
    expect(s3Key(fullEvent({ user_id: "" }), "request")).toContain("/kyc_verify/unknown/");
  });
  it("sanitizes an unsafe user_id (slash/space) into one safe segment", () => {
    expect(s3Key(fullEvent({ user_id: "acct/99 x" }), "request")).toBe(
      "2026/05/29/karza/kyc_verify/acct_99_x/11111111-2222-3333-4444-555555555555/request.json.gz"
    );
  });
});
