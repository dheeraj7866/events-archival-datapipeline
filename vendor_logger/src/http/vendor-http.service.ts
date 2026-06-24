import { Injectable, Inject } from '@nestjs/common';
import { v4 as uuidv4 } from 'uuid';
import {
  VENDOR_LOGGER_OPTIONS,
  VendorApiEvent,
  VendorCallOptions,
  VendorCallResult,
  VendorLoggerModuleOptions,
  VendorStatus,
} from '../types';
import { PiiRedactor } from '../pii/pii-redactor.service';
import { SqsDrainService } from '../queue/sqs-drain.service';
import { VendorMetricsService } from '../metrics/vendor-metrics.service';

@Injectable()
export class VendorHttpService {
  private readonly service: string;
  private readonly environment: string;
  private readonly maxPayloadBytes: number;

  constructor(
    private readonly pii: PiiRedactor,
    private readonly drain: SqsDrainService,
    private readonly metrics: VendorMetricsService,
    @Inject(VENDOR_LOGGER_OPTIONS) opts: VendorLoggerModuleOptions,
  ) {
    this.service = opts.serviceName;
    this.environment = opts.environment;
    this.maxPayloadBytes = opts.maxPayloadBytes ?? 512 * 1024;
  }

  async call<TReq, TRes>(
    requestPayload: TReq,
    fn: (req: TReq) => Promise<VendorCallResult<TRes>>,
    options: VendorCallOptions,
  ): Promise<TRes> {
    const requestId = uuidv4();
    const createdAt = new Date().toISOString();
    const startMs = Date.now();

    try {
      const response = await fn(requestPayload);
      const latencyMs = Date.now() - startMs;
      const status =
        response.httpStatus >= 200 && response.httpStatus < 300
          ? VendorStatus.SUCCESS
          : VendorStatus.FAILURE;

      this.logDirect({
        requestId,
        createdAt,
        latencyMs,
        httpStatus: response.httpStatus,
        status,
        vendorRefId: response.vendorRefId,
        requestPayload,
        responsePayload: response.data,
        options,
      });

      return response.data;
    } catch (err: any) {
      const latencyMs = Date.now() - startMs;
      const httpStatus: number = err?.response?.status ?? err?.statusCode ?? 0;
      const status = this.categorizeError(err);

      this.logDirect({
        requestId,
        createdAt,
        latencyMs,
        httpStatus,
        status,
        errorCode: err?.code,
        errorMessage: err?.message ?? String(err),
        requestPayload,
        responsePayload: err?.response?.data ?? null,
        options,
      });

      throw err;
    }
  }

  logDirect(params: {
    requestId: string;
    createdAt: string;
    latencyMs: number;
    httpStatus: number;
    status: VendorStatus;
    vendorRefId?: string;
    errorCode?: string;
    errorMessage?: string;
    requestPayload: unknown;
    responsePayload: unknown;
    options: VendorCallOptions;
  }): void {
    try {
      const event = this.buildEvent(params);
      this.drain.enqueue(event);
      this.metrics.recordCall({
        vendorId: params.options.vendorId,
        endpoint: params.options.endpoint,
        status: params.status,
        httpStatus: params.httpStatus,
        latencyMs: params.latencyMs,
      });
    } catch {
      // LOGGER_ERROR — never propagate to caller
    }
  }

  private buildEvent(params: {
    requestId: string;
    createdAt: string;
    latencyMs: number;
    httpStatus: number;
    status: VendorStatus;
    vendorRefId?: string;
    errorCode?: string;
    errorMessage?: string;
    requestPayload: unknown;
    responsePayload: unknown;
    options: VendorCallOptions;
  }): VendorApiEvent {
    const {
      requestId,
      createdAt,
      latencyMs,
      httpStatus,
      status,
      vendorRefId,
      errorCode,
      errorMessage,
      requestPayload,
      responsePayload,
      options,
    } = params;

    let panMasked: string | undefined;
    let mobileHash: string | undefined;
    let mobileLast4: string | undefined;
    let aadhaarLast4Hash: string | undefined;

    if (options.pan) {
      panMasked = this.pii.maskPan(options.pan);
    }
    if (options.mobile) {
      const m = this.pii.hashMobile(options.mobile);
      mobileHash = m.hash;
      mobileLast4 = m.last4;
    }
    if (options.aadhaarLast4) {
      aadhaarLast4Hash = this.pii.hashAadhaarLast4(options.aadhaarLast4);
    }

    const { reqStr, resStr, truncated, requestHash } = this.serializePayloads(requestPayload, responsePayload, this.maxPayloadBytes);

    return {
      schemaVersion: 1,
      requestId,
      createdAt,
      service: this.service,
      environment: this.environment,
      vendorId: options.vendorId,
      endpoint: options.endpoint,
      vendorRefId: vendorRefId ?? options.vendorRefId,
      loanLifecycleStage: options.loanLifecycleStage,
      loanApplicationNumber: options.loanApplicationNumber,
      userId: options.userId,
      panMasked,
      mobileHash,
      mobileLast4,
      aadhaarLast4Hash,
      consentId: options.consentId,
      status,
      httpStatus,
      latencyMs,
      errorCode,
      errorMessage,
      requestPayload: reqStr,
      responsePayload: resStr,
      payloadTruncated: truncated,
      requestHash,
    };
  }

  private serializePayloads(
    req: unknown,
    res: unknown,
    maxBytes: number,
  ): { reqStr: string; resStr: string; truncated: boolean; requestHash: string } {
    // Library sends RAW payloads — redaction happens in Lambda (two-tier design):
    //   S3 ← raw (KMS encrypted, Object Lock)  ← compliance audit layer
    //   ClickHouse ← PayloadRedactor.redact(raw)  ← operational query layer
    // SQS SSE-KMS (P2-2) is REQUIRED before production to protect PII in transit.
    let reqStr: string;
    let resStr: string;
    try {
      reqStr = JSON.stringify(req) ?? '';
    } catch {
      reqStr = String(req);
    }
    try {
      resStr = JSON.stringify(res) ?? '';
    } catch {
      resStr = String(res);
    }

    // Hash of the raw payload — chain of custody anchor for RBI audit
    const requestHash = this.pii.hashPayload(reqStr);

    let truncated = false;
    if (Buffer.byteLength(reqStr, 'utf8') > maxBytes) {
      reqStr = Buffer.from(reqStr, 'utf8').subarray(0, maxBytes).toString('utf8') + '...[TRUNCATED]';
      truncated = true;
    }
    if (Buffer.byteLength(resStr, 'utf8') > maxBytes) {
      resStr = Buffer.from(resStr, 'utf8').subarray(0, maxBytes).toString('utf8') + '...[TRUNCATED]';
      truncated = true;
    }
    return { reqStr, resStr, truncated, requestHash };
  }

  private categorizeError(err: any): VendorStatus {
    const code: string = err?.code ?? '';
    const msg: string = (err?.message ?? '').toLowerCase();

    if (
      code === 'ECONNABORTED' ||
      code === 'ETIMEDOUT' ||
      msg.includes('timeout') ||
      msg.includes('timed out')
    ) {
      return VendorStatus.TIMEOUT;
    }

    if (
      code === 'ECONNREFUSED' ||
      code === 'ENOTFOUND' ||
      code === 'ECONNRESET' ||
      code === 'EHOSTUNREACH' ||
      code === 'ENETUNREACH'
    ) {
      return VendorStatus.NETWORK_ERROR;
    }

    return VendorStatus.FAILURE;
  }
}
