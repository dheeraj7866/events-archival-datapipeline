import {
  SQSHandler,
  SQSRecord,
  SQSBatchResponse,
  SQSBatchItemFailure,
} from "aws-lambda";
import {
  S3Client,
  PutObjectCommand,
  HeadObjectCommand,
} from "@aws-sdk/client-s3";
import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";
import {
  SQSClient,
  SendMessageBatchCommand,
} from "@aws-sdk/client-sqs";
import { createClient, ClickHouseClient } from "@clickhouse/client";
import { gzipSync } from "zlib";
import { VendorApiEventWire } from "./contract/vendor-event.types";
import { PayloadRedactor } from "./contract/payload-redactor";

// ─── Config ───────────────────────────────────────────────────────────────────

const REGION = process.env.AWS_REGION!;
const S3_BUCKET = process.env.S3_BUCKET!;
const CH_HOST = process.env.CLICKHOUSE_HOST!;
const CH_PORT = Number(process.env.CLICKHOUSE_PORT ?? "9000");
const CH_DB = process.env.CLICKHOUSE_DATABASE ?? "vendor_archive";
const CH_USER = process.env.CLICKHOUSE_USER ?? "archiver";
const CH_SECRET_ARN = process.env.CLICKHOUSE_SECRET_ARN!;
const ENVIRONMENT = process.env.ENVIRONMENT ?? "staging";
const CH_RETRY_QUEUE_URL = process.env.CH_RETRY_QUEUE_URL ?? "";
const SUPPORTED_SCHEMA_VERSION = 1;

// ─── AWS clients (outside handler = reused across warm invocations) ────────────

const s3 = new S3Client({ region: REGION });
const sm = new SecretsManagerClient({ region: REGION });
const sqs = new SQSClient({ region: REGION });

// ─── ClickHouse client — initialised lazily once per container ────────────────

let chClient: ClickHouseClient | null = null;

async function getClickHouseClient(): Promise<ClickHouseClient> {
  if (chClient) return chClient;

  const secret = await sm.send(
    new GetSecretValueCommand({ SecretId: CH_SECRET_ARN })
  );
  const password = secret.SecretString ?? "";

  chClient = createClient({
    host: `http://${CH_HOST}:${CH_PORT}`,
    database: CH_DB,
    username: CH_USER,
    password,
    clickhouse_settings: {
      // Synchronous INSERT: the call only resolves once the rows are accepted, so a
      // failure is a real failure and the batch can be safely retried (CONVENTIONS §2.2).
      async_insert: 0,
      wait_for_async_insert: 0,
    },
  });

  return chClient;
}

// ─── ClickHouse row — must stay column-for-column identical to init.sql (§3) ──

export interface ClickHouseRow {
  schema_version: number;
  request_id: string;
  created_at: string;
  ingested_at: string;
  service: string;
  environment: string;
  vendor_id: string;
  endpoint: string;
  vendor_ref_id: string;
  loan_lifecycle_stage: string;
  loan_application_number: string | null;
  user_id: string;
  pan_masked: string;
  mobile_hash: string;
  mobile_last4: string;
  aadhaar_last4_hash: string;
  aadhaar_last4_encrypted: string;
  consent_id: string;
  status: string;
  http_status: number | null;
  latency_ms: number;
  error_code: string;
  error_message: string;
  s3_request_key: string;
  s3_response_key: string;
  request_payload: string;
  response_payload: string;
  payload_truncated: number;
  request_hash: string;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** YYYY/MM/DD from an ISO string, falling back when createdAt is missing/invalid. */
export function safeYmd(iso: string, fallbackIso: string): string {
  const dt = new Date(iso);
  const usable = Number.isNaN(dt.getTime()) ? new Date(fallbackIso) : dt;
  return usable.toISOString().slice(0, 10).replace(/-/g, "/");
}

/** An endpoint like `/kyc/verify` must not create extra S3 path segments (§5). */
export function sanitizeEndpoint(endpoint: string): string {
  return (endpoint || "unknown")
    .replace(/^\/+/, "")
    .replace(/[^A-Za-z0-9._-]+/g, "_")
    .replace(/^_+|_+$/g, "") || "unknown";
}

/** Parse a JSON string; undefined if it isn't valid JSON (e.g. truncated/[OVERSIZED]). */
function tryParse(s: string): unknown {
  try {
    return JSON.parse(s);
  } catch {
    return undefined;
  }
}

/**
 * Redact a payload for the ClickHouse (queryable) tier. The wire value is a string;
 * we parse it when possible so key-name redaction works, and fall back to scanning
 * the raw string when it isn't valid JSON. Returns a string for storage.
 */
export function redactForClickHouse(rawPayload: string): string {
  const parsed = tryParse(rawPayload);
  // The library always JSON.stringifies payloads, so parse only fails for a
  // truncated or [OVERSIZED] payload. We can't structurally redact those, and
  // PayloadRedactor only deep-scans embedded Aadhaar (not embedded PAN/mobile), so
  // storing the raw tail in the queryable tier risks leaking PII. Fail closed —
  // the full raw copy is preserved in S3 (CONVENTIONS §6). Tightening the library
  // redactor to scan embedded PAN/mobile is tracked as library P0-1 follow-up.
  if (parsed === undefined) return "[REDACTED:UNPARSEABLE]";
  const redacted = PayloadRedactor.redact(parsed);
  return typeof redacted === "string" ? redacted : JSON.stringify(redacted);
}

/**
 * Shared S3 prefix for all objects of one event:
 *   YYYY/MM/DD/{vendor_id}/{endpoint}/{user_id}/{request_id}
 * user_id sits between the endpoint slug and request_id. It falls back to "unknown"
 * when absent so the key is never .../undefined/... or a broken empty segment
 * (sanitizeEndpoint also maps "" and unsafe characters to a safe segment).
 */
function s3Prefix(event: VendorApiEventWire): string {
  const ymd = safeYmd(event.created_at, new Date().toISOString());
  const endpoint = sanitizeEndpoint(event.endpoint);
  const userFolder = sanitizeEndpoint(event.user_id ?? "unknown");
  return `${ymd}/${event.vendor_id}/${endpoint}/${userFolder}/${event.request_id}`;
}

export function s3Key(
  event: VendorApiEventWire,
  type: "request" | "response"
): string {
  return `${s3Prefix(event)}/${type}.json.gz`;
}

function s3MetaKey(event: VendorApiEventWire): string {
  return `${s3Prefix(event)}/meta.json`;
}

// ─── S3 write — raw payload, KMS + Legal Hold set inline on PutObject ─────────

async function writeToS3(
  event: VendorApiEventWire,
  type: "request" | "response",
  rawPayload: string
): Promise<string> {
  const key = s3Key(event, type);
  // S3 keeps the RAW payload (full-fidelity compliance archive). Redaction is only
  // applied to the ClickHouse copy (CONVENTIONS §6).
  const body = gzipSync(
    Buffer.from(
      JSON.stringify({
        meta: {
          request_id: event.request_id,
          service: event.service,
          vendor_id: event.vendor_id,
          endpoint: event.endpoint,
          created_at: event.created_at,
          environment: ENVIRONMENT,
        },
        payload: rawPayload,
      })
    )
  );

  await s3.send(
    new PutObjectCommand({
      Bucket: S3_BUCKET,
      Key: key,
      Body: body,
      ContentType: "application/gzip",
      ContentEncoding: "gzip",
      // Bucket policy requires aws:kms SSE for archive objects.
      ServerSideEncryption: "aws:kms",
      Metadata: {
        "x-request-id": event.request_id,
        "x-vendor-id": event.vendor_id,
        "x-environment": ENVIRONMENT,
      },
    })
  );

  return key;
}

// ─── S3 meta.json sidecar — plain JSON (not gzipped), alongside request/response ──

async function writeMetaToS3(event: VendorApiEventWire): Promise<string> {
  const key = s3MetaKey(event);
  // Field set mirrors the Athena Glue table (vendor_events_cold). No payloads.
  const meta = {
    schema_version: event.schema_version,
    request_id: event.request_id,
    created_at: event.created_at,
    service: event.service,
    environment: event.environment,
    vendor_id: event.vendor_id,
    endpoint: event.endpoint,
    loan_lifecycle_stage: event.loan_lifecycle_stage,
    loan_application_number: event.loan_application_number ?? null,
    user_id: event.user_id ?? "unknown",
    pan_masked: event.pan_masked ?? "",
    mobile_last4: event.mobile_last4 ?? "",
    aadhaar_last4_hash: event.aadhaar_last4_hash ?? "",
    consent_id: event.consent_id ?? "",
    status: event.status,
    http_status: event.http_status ?? null,
    latency_ms: event.latency_ms,
    request_hash: event.request_hash ?? "",
  };

  await s3.send(
    new PutObjectCommand({
      Bucket: S3_BUCKET,
      Key: key,
      Body: Buffer.from(JSON.stringify(meta)),
      ContentType: "application/json",
      // Same bucket-policy requirements as the payload objects (§5).
      ServerSideEncryption: "aws:kms",
      Metadata: {
        "x-request-id": event.request_id,
        "x-vendor-id": event.vendor_id,
        "x-environment": ENVIRONMENT,
      },
    })
  );

  return key;
}

// ─── ClickHouse batch INSERT ──────────────────────────────────────────────────

async function insertToClickHouse(
  ch: ClickHouseClient,
  rows: ClickHouseRow[]
): Promise<void> {
  await ch.insert({
    table: "vendor_api_events",
    values: rows,
    format: "JSONEachRow",
  });
}

// ─── Per-record processing ────────────────────────────────────────────────────

/**
 * Build the ClickHouse row from the snake_case wire event (§2.1, §6). The wire is
 * already 1:1 with the producer-owned columns, so this is mostly passthrough; the
 * Lambda's job is the added columns (ingested_at, s3_*_key, aadhaar_last4_encrypted),
 * payload redaction, and type coercion (bool→UInt8, nullable numbers). No I/O.
 */
export function mapToClickHouseRow(
  event: VendorApiEventWire,
  ingestedAt: string,
  reqKey: string,
  respKey: string
): ClickHouseRow {
  return {
    schema_version: event.schema_version,
    request_id: event.request_id,
    created_at: event.created_at,
    ingested_at: ingestedAt,
    service: event.service,
    environment: event.environment ?? ENVIRONMENT,
    vendor_id: event.vendor_id,
    endpoint: event.endpoint,
    vendor_ref_id: event.vendor_ref_id ?? "",
    // loan_lifecycle_stage is an Enum8 in CH (no '' member) — the v1 wire always
    // provides a valid value, so pass it through directly (no "" fallback).
    loan_lifecycle_stage: event.loan_lifecycle_stage,
    loan_application_number: event.loan_application_number ?? null,
    user_id: event.user_id ?? "",
    pan_masked: event.pan_masked ?? "",
    mobile_hash: event.mobile_hash ?? "",
    mobile_last4: event.mobile_last4 ?? "",
    aadhaar_last4_hash: event.aadhaar_last4_hash ?? "",
    // KMS encryption of Aadhaar last-4 is DEFERRED pending D2 — never fabricate it (§6).
    aadhaar_last4_encrypted: "",
    consent_id: event.consent_id ?? "",
    status: event.status,
    http_status: event.http_status ?? null,
    latency_ms: event.latency_ms,
    error_code: event.error_code ?? "",
    error_message: event.error_message ?? "",
    s3_request_key: reqKey,
    s3_response_key: respKey,
    request_payload: redactForClickHouse(event.request_payload),
    response_payload: redactForClickHouse(event.response_payload),
    payload_truncated: event.payload_truncated ? 1 : 0,
    request_hash: event.request_hash ?? "",
  };
}

/** HeadObject probe — true if the object already exists (idempotency check, item 5b). */
async function s3ObjectExists(key: string): Promise<boolean> {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: S3_BUCKET, Key: key }));
    return true;
  } catch (err: any) {
    const code = err?.$metadata?.httpStatusCode;
    if (code === 404 || err?.name === "NotFound" || err?.name === "NoSuchKey") return false;
    // Unknown HeadObject error — don't block archival; proceed to write (key is
    // deterministic, so a re-write is idempotent).
    console.warn(
      JSON.stringify({ level: "warn", message: "HeadObject failed; proceeding with write", key, error: String(err) })
    );
    return false;
  }
}

/** Re-route SQS message bodies to the CH retry queue (≤10 per batch). Throws on failure. */
async function sendToRetryQueue(bodies: string[]): Promise<void> {
  if (!CH_RETRY_QUEUE_URL) throw new Error("CH_RETRY_QUEUE_URL is not set");
  for (let i = 0; i < bodies.length; i += 10) {
    const chunk = bodies.slice(i, i + 10);
    const res = await sqs.send(
      new SendMessageBatchCommand({
        QueueUrl: CH_RETRY_QUEUE_URL,
        Entries: chunk.map((body, idx) => ({ Id: String(i + idx), MessageBody: body })),
      })
    );
    if (res.Failed?.length) {
      throw new Error(`retry-queue SendMessageBatch partial failure: ${res.Failed.length}`);
    }
  }
}

// ─── Per-record processing ────────────────────────────────────────────────────

async function processRecord(
  record: SQSRecord,
  ingestedAt: string
): Promise<ClickHouseRow | null> {
  const event: VendorApiEventWire = JSON.parse(record.body);

  // Schema-version guard (item 5e): only handle the contract this Lambda was built
  // for. Unknown versions are skipped (logged, not thrown) so a forward-rolled
  // producer can't wedge an old Lambda deployment.
  if (event.schema_version !== SUPPORTED_SCHEMA_VERSION) {
    console.warn(
      JSON.stringify({
        level: "warn",
        message: "Unsupported schema_version — skipping event",
        schema_version: event.schema_version,
        request_id: event.request_id,
      })
    );
    return null;
  }

  const reqKey = s3Key(event, "request");
  const respKey = s3Key(event, "response");

  // Idempotency (item 5b): if the request object already exists, this event was
  // already archived (re-delivery) — skip all three S3 writes.
  if (await s3ObjectExists(reqKey)) {
    console.log(
      JSON.stringify({ level: "info", message: "Already archived in S3 — skipping writes", request_id: event.request_id })
    );
  } else {
    // ① S3 FIRST — raw payloads + meta sidecar, written in parallel.
    await Promise.all([
      writeToS3(event, "request", event.request_payload),
      writeToS3(event, "response", event.response_payload),
      writeMetaToS3(event),
    ]);
  }

  // ② Map wire → ClickHouse row (s3 keys are deterministic from the event).
  return mapToClickHouseRow(event, ingestedAt, reqKey, respKey);
}

// ─── Main handler ─────────────────────────────────────────────────────────────

export const handler: SQSHandler = async (event): Promise<SQSBatchResponse> => {
  const failedItems: SQSBatchItemFailure[] = [];
  const ch = await getClickHouseClient();
  const now = new Date().toISOString();

  // Successful rows paired with their source SQS body (for retry-queue routing).
  const toInsert: { row: ClickHouseRow; body: string }[] = [];

  const results = await Promise.allSettled(
    event.Records.map((record) => processRecord(record, now))
  );

  for (let i = 0; i < results.length; i++) {
    const result = results[i];
    const record = event.Records[i];
    if (result.status === "rejected") {
      // Parse / S3 failure → retry via the MAIN queue (→ DLQ after 5 attempts).
      failedItems.push({ itemIdentifier: record.messageId });
      console.error(
        JSON.stringify({
          level: "error",
          message: "Failed to process SQS record",
          messageId: record.messageId,
          error: String(result.reason),
        })
      );
    } else if (result.value === null) {
      // Skipped (unsupported schema_version) — treated as success, no row.
    } else {
      toInsert.push({ row: result.value, body: record.body });
    }
  }

  // Batch INSERT to ClickHouse. On failure (item 5d), re-route the original messages
  // to the CH retry queue and return SUCCESS so the MAIN queue does NOT retry/DLQ —
  // S3 is already written and CH dedups by request_id, so reprocessing is safe.
  if (toInsert.length > 0) {
    try {
      await insertToClickHouse(ch, toInsert.map((t) => t.row));
    } catch (err) {
      console.error(
        JSON.stringify({
          level: "error",
          message: "ClickHouse INSERT failed — routing batch to CH retry queue",
          error: String(err),
          rowCount: toInsert.length,
        })
      );
      try {
        await sendToRetryQueue(toInsert.map((t) => t.body));
      } catch (retryErr) {
        // Couldn't even reach the retry queue → fall back to MAIN-queue retry so the
        // events are not lost (worst case: CH down AND retry queue unreachable).
        console.error(
          JSON.stringify({
            level: "error",
            message: "CH retry-queue send failed — falling back to main-queue retry",
            error: String(retryErr),
          })
        );
        return {
          batchItemFailures: event.Records.map((r) => ({ itemIdentifier: r.messageId })),
        };
      }
    }
  }

  // NOTE: never log requestPayload/responsePayload — only safe identifiers (§12).
  console.log(
    JSON.stringify({
      level: "info",
      message: "Batch processed",
      total: event.Records.length,
      inserted: toInsert.length,
      failed: failedItems.length,
    })
  );

  return { batchItemFailures: failedItems };
};
