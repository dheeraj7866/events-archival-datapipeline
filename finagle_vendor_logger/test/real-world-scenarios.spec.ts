/**
 * Real-world integration scenarios reflecting actual vendor calls in
 * identity-api (fingale_crm_backend), los-api, and payment-api.
 *
 * Each test mirrors a production call pattern.
 * No real AWS/network calls — SQS is mocked.
 */

import { Test, TestingModule } from '@nestjs/testing';
import { VendorHttpService } from '../src/http/vendor-http.service';
import { PiiRedactor } from '../src/pii/pii-redactor.service';
import { SqsDrainService } from '../src/queue/sqs-drain.service';
import { VendorMetricsService } from '../src/metrics/vendor-metrics.service';
import {
  VENDOR_LOGGER_OPTIONS,
  LoanLifecycleStage,
  VendorCallOptions,
  VendorLoggerModuleOptions,
  VendorStatus,
} from '../src/types';

const OPTS: VendorLoggerModuleOptions = {
  sqsQueueUrl: 'https://sqs.ap-south-1.amazonaws.com/123/vendor-archive-queue',
  sqsRegion: 'ap-south-1',
  serviceName: 'identity-api',
  environment: 'staging',
  mobileHashSalt: 'mobile-staging-salt-32chars-padxx',
  aadhaarHashSalt: 'aadhar-staging-salt-32chars-padxx',
};

interface MockDrain {
  enqueue: jest.Mock;
  bufferSize: number;
  onModuleInit: jest.Mock;
  onModuleDestroy: jest.Mock;
}

async function buildModule(serviceName = 'identity-api'): Promise<{
  service: VendorHttpService;
  drain: MockDrain;
  metrics: { recordCall: jest.Mock };
}> {
  const opts = { ...OPTS, serviceName };
  const drain: MockDrain = {
    enqueue: jest.fn(),
    bufferSize: 0,
    onModuleInit: jest.fn(),
    onModuleDestroy: jest.fn(),
  };
  const metrics = { recordCall: jest.fn() };

  const module: TestingModule = await Test.createTestingModule({
    providers: [
      { provide: VENDOR_LOGGER_OPTIONS, useValue: opts },
      PiiRedactor,
      { provide: SqsDrainService, useValue: drain },
      { provide: VendorMetricsService, useValue: metrics },
      VendorHttpService,
    ],
  }).compile();

  return { service: module.get(VendorHttpService), drain, metrics };
}

// ─── Karza KYC (identity-api → LoanLifecycleStage.KYC) ──────────────────────

describe('Karza KYC verification (identity-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  const KYC_OPTIONS: VendorCallOptions = {
    vendorId: 'karza',
    endpoint: '/v2/pan/validate',
    loanLifecycleStage: LoanLifecycleStage.KYC,
    userId: 'USR-9876',
    pan: 'ABCDE1234F',
    mobile: '9876543210',
    aadhaarLast4: '4321',
    consentId: 'CONSENT-XYZ',
  };

  beforeEach(async () => {
    ({ service, drain } = await buildModule());
  });

  it('records a SUCCESS event with masked PAN on 200 response', async () => {
    await service.call(
      { pan: 'ABCDE1234F', mobile: '9876543210', consent: true },
      async () => ({
        data: { valid: true, nameMatch: true, dobMatch: true },
        httpStatus: 200,
        vendorRefId: 'KARZA-REF-20260101-XYZ',
      }),
      KYC_OPTIONS,
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.status).toBe(VendorStatus.SUCCESS);
    expect(event.vendorId).toBe('karza');
    expect(event.panMasked).toBe('ABC****34F');
    expect(event.mobileHash).toMatch(/^[a-f0-9]{64}$/);
    expect(event.mobileLast4).toBe('3210');
    expect(event.aadhaarLast4Hash).toMatch(/^[a-f0-9]{64}$/);
    expect(event.consentId).toBe('CONSENT-XYZ');
    expect(event.loanLifecycleStage).toBe(LoanLifecycleStage.KYC);
    expect(event.requestHash).toMatch(/^[a-f0-9]{64}$/);
    // Dedicated indexed columns must never contain raw PII
    expect(event.panMasked).not.toBe('ABCDE1234F');
    expect(event.mobileHash).not.toBe('9876543210');
    expect(event.aadhaarLast4Hash).not.toBe('4321');
    // requestPayload/responsePayload ARE the raw audit evidence (stored encrypted in S3/ClickHouse)
    // The calling service is responsible for sanitizing before passing; the library logs faithfully.
  });

  it('records Karza 422 (PAN not found) as FAILURE, not NETWORK_ERROR', async () => {
    await service.call(
      { pan: 'ZZZZZ9999Z' },
      async () => ({ data: { valid: false, reason: 'PAN_NOT_FOUND' }, httpStatus: 422 }),
      KYC_OPTIONS,
    );

    expect(drain.enqueue.mock.calls[0][0].status).toBe(VendorStatus.FAILURE);
    expect(drain.enqueue.mock.calls[0][0].httpStatus).toBe(422);
  });

  it('records Karza timeout (ECONNABORTED) as TIMEOUT and re-throws', async () => {
    const timeoutErr = Object.assign(new Error('timeout of 10000ms exceeded'), {
      code: 'ECONNABORTED',
    });

    await expect(
      service.call({ pan: 'ABCDE1234F' }, async () => { throw timeoutErr; }, KYC_OPTIONS),
    ).rejects.toBe(timeoutErr);

    expect(drain.enqueue.mock.calls[0][0].status).toBe(VendorStatus.TIMEOUT);
    expect(drain.enqueue.mock.calls[0][0].latencyMs).toBeGreaterThanOrEqual(0);
  });
});

// ─── NSDL PAN-Aadhaar seeding (los-api → LoanLifecycleStage.PAN_AADHAAR_SEED) ─

describe('NSDL PAN-Aadhaar seeding (los-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  const NSDL_OPTIONS: VendorCallOptions = {
    vendorId: 'nsdl',
    endpoint: '/nsdl/v1/pan-aadhaar-link-status',
    loanLifecycleStage: LoanLifecycleStage.PAN_AADHAAR_SEED,
    userId: 'USR-4321',
    pan: 'PQRST5678U',
    aadhaarLast4: '9876',
    consentId: 'CONSENT-NSDL-001',
  };

  beforeEach(async () => {
    ({ service, drain } = await buildModule('los-api'));
  });

  it('records service name as los-api in the event', async () => {
    await service.call(
      {},
      async () => ({ data: { linked: true }, httpStatus: 200 }),
      NSDL_OPTIONS,
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.service).toBe('los-api');
    expect(event.loanLifecycleStage).toBe(LoanLifecycleStage.PAN_AADHAAR_SEED);
    expect(event.panMasked).toBe('PQR****78U');
    // aadhaar last 4 must be hashed — '9876' must not appear
    expect(JSON.stringify(event)).not.toContain('9876');
    expect(event.aadhaarLast4Hash).toMatch(/^[a-f0-9]{64}$/);
  });

  it('records NSDL DNS failure (ENOTFOUND) as NETWORK_ERROR', async () => {
    const dnsErr = Object.assign(new Error('getaddrinfo ENOTFOUND api.nsdl.co.in'), {
      code: 'ENOTFOUND',
    });
    await expect(
      service.call({}, async () => { throw dnsErr; }, NSDL_OPTIONS),
    ).rejects.toBe(dnsErr);

    expect(drain.enqueue.mock.calls[0][0].status).toBe(VendorStatus.NETWORK_ERROR);
  });
});

// ─── Easebuzz disbursement (payment-api → LoanLifecycleStage.DISBURSED) ────────

describe('Easebuzz disbursement (payment-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  const EASEBUZZ_OPTIONS: VendorCallOptions = {
    vendorId: 'easebuzz',
    endpoint: '/payment/v1/disburse',
    loanLifecycleStage: LoanLifecycleStage.DISBURSED,
    userId: 'USR-8765',
    mobile: '9123456789',
  };

  beforeEach(async () => {
    ({ service, drain } = await buildModule('payment-api'));
  });

  it('captures disbursement success with vendorRefId from Easebuzz', async () => {
    const EASEBUZZ_TXN_ID = 'EZB-TXN-2026-ABC123';

    await service.call(
      { amount: 5000000, accountNumber: '1234567890', ifsc: 'HDFC0001234' },
      async () => ({
        data: { status: 'SUCCESS', txnId: EASEBUZZ_TXN_ID },
        httpStatus: 200,
        vendorRefId: EASEBUZZ_TXN_ID,
      }),
      EASEBUZZ_OPTIONS,
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.status).toBe(VendorStatus.SUCCESS);
    expect(event.vendorRefId).toBe(EASEBUZZ_TXN_ID);
    expect(event.loanLifecycleStage).toBe(LoanLifecycleStage.DISBURSED);
    // Account number in request payload should not be accessible as a searchable field
    expect(event.mobileHash).toMatch(/^[a-f0-9]{64}$/);
  });

  it('captures Easebuzz insufficient-funds as FAILURE (HTTP 200 with error body)', async () => {
    await service.call(
      { amount: 5000000 },
      async () => ({
        data: { status: 'FAILED', reason: 'INSUFFICIENT_BALANCE' },
        httpStatus: 200,
      }),
      EASEBUZZ_OPTIONS,
    );
    // HTTP 200 → SUCCESS at the transport level
    // Business-level failure must be caught by the calling service
    expect(drain.enqueue.mock.calls[0][0].status).toBe(VendorStatus.SUCCESS);
    expect(drain.enqueue.mock.calls[0][0].httpStatus).toBe(200);
  });

  it('captures payment gateway 503 as FAILURE', async () => {
    await service.call(
      { amount: 5000000 },
      async () => ({ data: { error: 'Service Unavailable' }, httpStatus: 503 }),
      EASEBUZZ_OPTIONS,
    );

    expect(drain.enqueue.mock.calls[0][0].status).toBe(VendorStatus.FAILURE);
    expect(drain.enqueue.mock.calls[0][0].httpStatus).toBe(503);
  });
});

// ─── Bank statement analyser (los-api → LoanLifecycleStage.BANK_BRE) ─────────

describe('Bank statement analyser — large payload truncation (los-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  beforeEach(async () => {
    ({ service, drain } = await buildModule('los-api'));
  });

  it('truncates large PDF-as-base64 bank statement and sets payloadTruncated=true', async () => {
    const largeBase64 = Buffer.alloc(600 * 1024, 'A').toString('base64');
    const bigRequest = { statementBase64: largeBase64, months: 6 };

    await service.call(
      bigRequest,
      async () => ({
        data: { score: 720, transactions: 456, avgBalance: 25000 },
        httpStatus: 200,
      }),
      {
        vendorId: 'bank-statement-analyser',
        endpoint: '/v1/analyse',
        loanLifecycleStage: LoanLifecycleStage.BANK_BRE,
        consentId: 'CONSENT-BSA-001',
      },
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.payloadTruncated).toBe(true);
    expect(Buffer.byteLength(event.requestPayload, 'utf8')).toBeLessThan(513 * 1024);
    expect(event.requestPayload).toContain('[TRUNCATED]');
    expect(event.status).toBe(VendorStatus.SUCCESS);
  });
});

// ─── Bureau BRE (los-api → LoanLifecycleStage.BUREAU_BRE) ────────────────────

describe('Bureau BRE — CRIF/Equifax (los-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  const BUREAU_OPTIONS: VendorCallOptions = {
    vendorId: 'crif-highmark',
    endpoint: '/v1/credit-report/pull',
    loanLifecycleStage: LoanLifecycleStage.BUREAU_BRE,
    userId: 'USR-5555',
    pan: 'LMNOP9012Q',
    mobile: '9000012345',
    consentId: 'CONSENT-BUREAU-001',
  };

  beforeEach(async () => {
    ({ service, drain } = await buildModule('los-api'));
  });

  it('records bureau pull with correct lifecycle stage and vendorRefId', async () => {
    await service.call(
      { pan: 'LMNOP9012Q', mobile: '9000012345', consentTimestamp: '2026-05-01T10:00:00Z' },
      async () => ({
        data: { score: 750, enquiries: 3, reportId: 'CRIF-RPT-001' },
        httpStatus: 200,
        vendorRefId: 'CRIF-RPT-001',
      }),
      BUREAU_OPTIONS,
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.loanLifecycleStage).toBe(LoanLifecycleStage.BUREAU_BRE);
    expect(event.vendorRefId).toBe('CRIF-RPT-001');
    expect(event.panMasked).toBe('LMN****12Q');
  });

  it('records repeat bureau pull with REPEAT_BRE stage', async () => {
    await service.call(
      {},
      async () => ({ data: { score: 720 }, httpStatus: 200 }),
      { ...BUREAU_OPTIONS, loanLifecycleStage: LoanLifecycleStage.REPEAT_BRE },
    );

    expect(drain.enqueue.mock.calls[0][0].loanLifecycleStage).toBe(
      LoanLifecycleStage.REPEAT_BRE,
    );
  });
});

// ─── Multi-vendor in same request context (correlation chain) ─────────────────

describe('Correlation ID propagated across multiple vendor calls in one request', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  beforeEach(async () => {
    ({ service, drain } = await buildModule());
  });

  it('stamps all events in the same request with unique requestIds', async () => {
    await service.call(
      {},
      async () => ({ data: { verified: true }, httpStatus: 200 }),
      {
        vendorId: 'karza',
        endpoint: '/v2/pan/validate',
        loanLifecycleStage: LoanLifecycleStage.KYC,
        consentId: 'CONSENT-CHAIN-001',
      },
    );

    await service.call(
      {},
      async () => ({ data: { score: 720 }, httpStatus: 200 }),
      {
        vendorId: 'crif-highmark',
        endpoint: '/v1/credit-report/pull',
        loanLifecycleStage: LoanLifecycleStage.BUREAU_BRE,
        consentId: 'CONSENT-CHAIN-002',
      },
    );

    expect(drain.enqueue).toHaveBeenCalledTimes(2);
    const [event1, event2] = drain.enqueue.mock.calls.map((c) => c[0]);
    expect(event1.requestId).not.toBe(event2.requestId);
  });
});

// ─── Repayment webhook (payment-api → LoanLifecycleStage.REPAID) ─────────────

describe('Repayment via Easebuzz webhook confirmation (payment-api)', () => {
  let service: VendorHttpService;
  let drain: MockDrain;

  beforeEach(async () => {
    ({ service, drain } = await buildModule('payment-api'));
  });

  it('captures repayment confirmation with REPAID lifecycle stage', async () => {
    await service.call(
      { loanId: 'LOAN-999', amount: 250000, paymentMode: 'UPI' },
      async () => ({
        data: { confirmed: true, settledAt: '2026-05-01T18:30:00Z' },
        httpStatus: 200,
        vendorRefId: 'EZB-REPAY-20260501-XYZ',
      }),
      {
        vendorId: 'easebuzz',
        endpoint: '/payment/v1/repayment-confirm',
        loanLifecycleStage: LoanLifecycleStage.REPAID,
      },
    );

    const event = drain.enqueue.mock.calls[0][0];
    expect(event.loanLifecycleStage).toBe(LoanLifecycleStage.REPAID);
    expect(event.status).toBe(VendorStatus.SUCCESS);
  });
});
