import { gunzipSync } from "zlib";
import { fullEvent } from "./fixtures";

// ─── Mock AWS SDK + ClickHouse client BEFORE importing the handler ────────────
// (jest hoists jest.mock; vars referenced inside factories must be prefixed `mock`.)

// S3 send distinguishes HeadObject (idempotency probe) from PutObject. Default:
// HeadObject → 404 (not found, so writes proceed); PutObject → success.
const mockS3Send = jest.fn((cmd: any) => {
  if (cmd && cmd.__cmd === "head") {
    return Promise.reject({ name: "NotFound", $metadata: { httpStatusCode: 404 } });
  }
  return Promise.resolve({});
});
const mockPutObjectCommand = jest.fn((input: unknown) => ({ __cmd: "put", input }));
const mockHeadObjectCommand = jest.fn((input: unknown) => ({ __cmd: "head", input }));
jest.mock("@aws-sdk/client-s3", () => ({
  S3Client: jest.fn(() => ({ send: mockS3Send })),
  PutObjectCommand: mockPutObjectCommand,
  HeadObjectCommand: mockHeadObjectCommand,
}));

const mockSmSend = jest.fn().mockResolvedValue({ SecretString: "ch-password" });
jest.mock("@aws-sdk/client-secrets-manager", () => ({
  SecretsManagerClient: jest.fn(() => ({ send: mockSmSend })),
  GetSecretValueCommand: jest.fn((input: unknown) => ({ input })),
}));

const mockSqsSend = jest.fn().mockResolvedValue({});
const mockSendMessageBatchCommand = jest.fn((input: unknown) => ({ __cmd: "sendbatch", input }));
jest.mock("@aws-sdk/client-sqs", () => ({
  SQSClient: jest.fn(() => ({ send: mockSqsSend })),
  SendMessageBatchCommand: mockSendMessageBatchCommand,
}));

const mockInsert = jest.fn().mockResolvedValue({});
jest.mock("@clickhouse/client", () => ({
  createClient: jest.fn(() => ({ insert: mockInsert })),
}));

process.env.S3_BUCKET = "vendor-archive-staging-aps2";
process.env.CLICKHOUSE_SECRET_ARN = "arn:secret";
process.env.ENVIRONMENT = "staging";
process.env.CH_RETRY_QUEUE_URL =
  "https://sqs.ap-south-2.amazonaws.com/761520024839/vendor-archive-staging-ch-retry-q";

import { handler } from "../src/index";

function sqsEvent(bodies: string[]) {
  return {
    Records: bodies.map((body, i) => ({
      messageId: `msg-${i}`,
      body,
    })),
  } as any;
}

async function invoke(evt: any) {
  return (handler as any)(evt, {}, () => {});
}

describe("handler — end-to-end (mocked AWS): S3 raw, ClickHouse redacted", () => {
  it("writes raw payloads to S3 and inserts a redacted snake_case row", async () => {
    const evt = fullEvent();
    const res = await invoke(sqsEvent([JSON.stringify(evt)]));

    // No failures reported
    expect(res).toEqual({ batchItemFailures: [] });

    // S3: request + response + meta.json — all KMS + Legal Hold, all under the
    // .../{user_id}/{request_id}/ prefix (user_id 'user-555' from the event).
    expect(mockPutObjectCommand).toHaveBeenCalledTimes(3);
    const putInputs = mockPutObjectCommand.mock.calls.map((c) => c[0] as any);
    for (const input of putInputs) {
      expect(input.Bucket).toBe("vendor-archive-staging-aps2");
      expect(input.ServerSideEncryption).toBe("aws:kms");
      expect(input.ObjectLockLegalHoldStatus).toBe("ON");
      expect(input.Key).toMatch(
        /^2026\/05\/29\/karza\/kyc_verify\/user-555\/[\w-]+\/(request\.json\.gz|response\.json\.gz|meta\.json)$/
      );
    }

    // S3 body holds the RAW PAN (full-fidelity compliance copy)
    const reqInput = putInputs.find((i) => i.Key.endsWith("request.json.gz"));
    const s3Doc = JSON.parse(gunzipSync(reqInput.Body).toString("utf8"));
    expect(s3Doc.payload).toContain("ABCDE1234F"); // raw PAN preserved in S3

    // meta.json sidecar: plain JSON (not gzipped), with the key event fields
    const metaInput = putInputs.find((i) => i.Key.endsWith("meta.json"));
    expect(metaInput.ContentType).toBe("application/json");
    const meta = JSON.parse(metaInput.Body.toString("utf8"));
    expect(meta).toMatchObject({
      request_id: evt.request_id, user_id: "user-555", vendor_id: "karza",
      status: "SUCCESS", endpoint: "/kyc/verify", loan_lifecycle_stage: "KYC",
    });
    // meta is metadata only — it must NOT carry the raw payload
    expect(JSON.stringify(meta)).not.toContain("ABCDE1234F");

    // the CH s3 key reflects the new user_id-folder path
    const row0 = mockInsert.mock.calls[0][0].values[0];
    expect(row0.s3_request_key).toMatch(
      /^2026\/05\/29\/karza\/kyc_verify\/user-555\/[\w-]+\/request\.json\.gz$/
    );

    // ClickHouse: a single batch insert with a redacted, snake_case row
    expect(mockInsert).toHaveBeenCalledTimes(1);
    const insertArg = mockInsert.mock.calls[0][0];
    expect(insertArg.table).toBe("vendor_api_events");
    expect(insertArg.format).toBe("JSONEachRow");
    const row = insertArg.values[0];

    expect(row.request_id).toBe(evt.request_id);
    expect(row.vendor_id).toBe("karza");
    expect(row.status).toBe("SUCCESS");
    expect(row.aadhaar_last4_encrypted).toBe("");
    expect(row.s3_request_key).toMatch(/request\.json\.gz$/);
    // redacted in CH, NOT raw
    expect(row.request_payload).not.toContain("ABCDE1234F");
    expect(row.request_payload).toContain("ABC****34F");
    // no camelCase leakage
    expect((row as any).requestId).toBeUndefined();
  });

  it("isolates a poison-pill record without failing the whole batch", async () => {
    const good = JSON.stringify(fullEvent({ request_id: "good-1" }));
    const bad = "{ this is not valid json";
    const res = await invoke(sqsEvent([good, bad]));

    // Only the malformed record is reported for retry
    expect(res.batchItemFailures).toEqual([{ itemIdentifier: "msg-1" }]);
    // The good record still made it into a CH insert
    expect(mockInsert).toHaveBeenCalledTimes(1);
    expect(mockInsert.mock.calls[0][0].values).toHaveLength(1);
  });

  it("routes to the CH retry queue on insert failure (no main-queue retry)", async () => {
    mockInsert.mockRejectedValueOnce(new Error("CH down"));
    const res = await invoke(
      sqsEvent([
        JSON.stringify(fullEvent({ request_id: "a" })),
        JSON.stringify(fullEvent({ request_id: "b" })),
      ])
    );
    // success → the MAIN queue must NOT retry / DLQ
    expect(res.batchItemFailures).toEqual([]);
    // both messages were re-routed to the retry queue
    expect(mockSqsSend).toHaveBeenCalledTimes(1);
    const sendInput = mockSendMessageBatchCommand.mock.calls[0][0] as any;
    expect(sendInput.QueueUrl).toContain("ch-retry-q");
    expect(sendInput.Entries).toHaveLength(2);
  });

  it("falls back to main-queue retry if the retry queue is also unreachable", async () => {
    mockInsert.mockRejectedValueOnce(new Error("CH down"));
    mockSqsSend.mockRejectedValueOnce(new Error("SQS down"));
    const res = await invoke(sqsEvent([JSON.stringify(fullEvent({ request_id: "x" }))]));
    expect(res.batchItemFailures).toEqual([{ itemIdentifier: "msg-0" }]);
  });

  it("skips S3 writes when the object already exists (idempotency)", async () => {
    mockS3Send.mockImplementationOnce(() => Promise.resolve({})); // HeadObject → exists
    const res = await invoke(sqsEvent([JSON.stringify(fullEvent({ request_id: "dup-1" }))]));
    expect(res.batchItemFailures).toEqual([]);
    expect(mockPutObjectCommand).not.toHaveBeenCalled(); // no S3 writes
    expect(mockInsert).toHaveBeenCalledTimes(1); // but still inserted to CH
  });

  it("skips events with an unsupported schema_version (no row, no failure)", async () => {
    const res = await invoke(
      sqsEvent([JSON.stringify(fullEvent({ schema_version: 2, request_id: "v2" }))])
    );
    expect(res.batchItemFailures).toEqual([]);
    expect(mockPutObjectCommand).not.toHaveBeenCalled(); // skipped before any write
    expect(mockInsert).not.toHaveBeenCalled(); // no insert
  });
});
