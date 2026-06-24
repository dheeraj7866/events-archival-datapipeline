import { Test, TestingModule } from '@nestjs/testing';
import { VendorHttpService } from '../src/http/vendor-http.service';
import { PiiRedactor } from '../src/pii/pii-redactor.service';
import { SqsDrainService } from '../src/queue/sqs-drain.service';
import { VendorMetricsService } from '../src/metrics/vendor-metrics.service';
import {
  VENDOR_LOGGER_OPTIONS,
  LoanLifecycleStage,
  VendorCallOptions,
  VendorCallResult,
  VendorLoggerModuleOptions,
  VendorStatus,
  toWireEvent,
} from '../src/types';

const OPTS: VendorLoggerModuleOptions = {
  sqsQueueUrl: 'https://sqs.ap-south-1.amazonaws.com/123/test',
  sqsRegion: 'ap-south-1',
  serviceName: 'identity-api',
  environment: 'test',
  mobileHashSalt: 'mobile-test-salt-32chars-padding!!',
  aadhaarHashSalt: 'aadhar-test-salt-32chars-padding!!',
};

const BASE_OPTIONS: VendorCallOptions = {
  vendorId: 'karza',
  endpoint: '/v2/kyc/verify',
  loanLifecycleStage: LoanLifecycleStage.KYC,
  userId: 'USR-001',
  pan: 'ABCDE1234F',
  mobile: '9876543210',
  consentId: 'CONSENT-UNIT-TEST',
};

describe('VendorHttpService', () => {
  let service: VendorHttpService;
  let drainEnqueue: jest.SpyInstance;
  let metricsRecord: jest.SpyInstance;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        { provide: VENDOR_LOGGER_OPTIONS, useValue: OPTS },
        PiiRedactor,
        {
          provide: SqsDrainService,
          useValue: {
            enqueue: jest.fn(),
            bufferSize: 0,
            onModuleInit: jest.fn(),
            onModuleDestroy: jest.fn(),
          },
        },
        {
          provide: VendorMetricsService,
          useValue: { recordCall: jest.fn() },
        },
        VendorHttpService,
      ],
    }).compile();

    service = module.get(VendorHttpService);
    drainEnqueue = jest.spyOn(module.get(SqsDrainService), 'enqueue');
    metricsRecord = jest.spyOn(module.get(VendorMetricsService), 'recordCall');
  });

  describe('successful call', () => {
    it('returns the vendor response data', async () => {
      const fn = jest.fn().mockResolvedValue({
        data: { verified: true },
        httpStatus: 200,
      } as VendorCallResult<{ verified: boolean }>);

      const result = await service.call({ pan: 'ABCDE1234F' }, fn, BASE_OPTIONS);

      expect(result).toEqual({ verified: true });
    });

    it('enqueues an event with SUCCESS status', async () => {
      const fn = jest.fn().mockResolvedValue({ data: { ok: true }, httpStatus: 200 });
      await service.call({}, fn, BASE_OPTIONS);

      expect(drainEnqueue).toHaveBeenCalledTimes(1);
      const event = drainEnqueue.mock.calls[0][0];
      expect(event.schemaVersion).toBe(1);
      expect(event.status).toBe(VendorStatus.SUCCESS);
      expect(event.httpStatus).toBe(200);
      expect(event.vendorId).toBe('karza');
      expect(event.service).toBe('identity-api');
      expect(event.environment).toBe('test');
    });

    it('flows loanApplicationNumber through event and wire', async () => {
      const fn = jest.fn().mockResolvedValue({ data: { ok: true }, httpStatus: 200 });
      await service.call({}, fn, { ...BASE_OPTIONS, loanApplicationNumber: 'LAN-2026-001' });

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.loanApplicationNumber).toBe('LAN-2026-001');
      const wire = toWireEvent(event);
      expect(wire.loan_application_number).toBe('LAN-2026-001');
    });

    it('masks PAN in the enqueued event', async () => {
      const fn = jest.fn().mockResolvedValue({ data: {}, httpStatus: 200 });
      await service.call({}, fn, { ...BASE_OPTIONS, pan: 'ABCDE1234F' });

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.panMasked).toBe('ABC****34F');
      expect(event.panMasked).not.toContain('ABCDE1234F');
    });

    it('hashes mobile in the enqueued event — never stores plaintext', async () => {
      const fn = jest.fn().mockResolvedValue({ data: {}, httpStatus: 200 });
      await service.call({}, fn, { ...BASE_OPTIONS, mobile: '9876543210' });

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.mobileHash).toMatch(/^[a-f0-9]{64}$/);
      expect(event.mobileLast4).toBe('3210');
      expect(JSON.stringify(event)).not.toContain('9876543210');
    });

    it('records metrics on success', async () => {
      const fn = jest.fn().mockResolvedValue({ data: {}, httpStatus: 200 });
      await service.call({}, fn, BASE_OPTIONS);

      expect(metricsRecord).toHaveBeenCalledWith(
        expect.objectContaining({ vendorId: 'karza', status: VendorStatus.SUCCESS }),
      );
    });

    it('marks 4xx responses as FAILURE', async () => {
      const fn = jest.fn().mockResolvedValue({ data: { error: 'bad request' }, httpStatus: 400 });
      await service.call({}, fn, BASE_OPTIONS);

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.status).toBe(VendorStatus.FAILURE);
    });
  });

  describe('error categorization', () => {
    it('categorizes ECONNABORTED as TIMEOUT', async () => {
      const err = Object.assign(new Error('timeout of 5000ms exceeded'), { code: 'ECONNABORTED' });
      const fn = jest.fn().mockRejectedValue(err);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toThrow(err);

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.status).toBe(VendorStatus.TIMEOUT);
    });

    it('categorizes ETIMEDOUT as TIMEOUT', async () => {
      const err = Object.assign(new Error('connect ETIMEDOUT'), { code: 'ETIMEDOUT' });
      const fn = jest.fn().mockRejectedValue(err);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toThrow(err);
      expect(drainEnqueue.mock.calls[0][0].status).toBe(VendorStatus.TIMEOUT);
    });

    it('categorizes ECONNREFUSED as NETWORK_ERROR', async () => {
      const err = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' });
      const fn = jest.fn().mockRejectedValue(err);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toThrow(err);
      expect(drainEnqueue.mock.calls[0][0].status).toBe(VendorStatus.NETWORK_ERROR);
    });

    it('categorizes ENOTFOUND as NETWORK_ERROR', async () => {
      const err = Object.assign(new Error('getaddrinfo ENOTFOUND vendor.example.com'), {
        code: 'ENOTFOUND',
      });
      const fn = jest.fn().mockRejectedValue(err);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toThrow(err);
      expect(drainEnqueue.mock.calls[0][0].status).toBe(VendorStatus.NETWORK_ERROR);
    });

    it('categorizes generic errors as FAILURE', async () => {
      const err = new Error('unexpected JSON');
      const fn = jest.fn().mockRejectedValue(err);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toThrow(err);
      expect(drainEnqueue.mock.calls[0][0].status).toBe(VendorStatus.FAILURE);
    });

    it('re-throws the original error — fail-open', async () => {
      const originalError = new Error('vendor down');
      const fn = jest.fn().mockRejectedValue(originalError);

      await expect(service.call({}, fn, BASE_OPTIONS)).rejects.toBe(originalError);
    });
  });

  describe('fail-open — logger errors never break vendor call', () => {
    it('returns vendor response even when enqueue throws', async () => {
      drainEnqueue.mockImplementation(() => {
        throw new Error('SQS unavailable');
      });
      const fn = jest.fn().mockResolvedValue({ data: { ok: true }, httpStatus: 200 });

      const result = await service.call({}, fn, BASE_OPTIONS);
      expect(result).toEqual({ ok: true });
    });
  });

  describe('payload truncation', () => {
    it('truncates request payload exceeding maxPayloadBytes and sets payloadTruncated=true', async () => {
      const largePayload = { data: 'x'.repeat(600 * 1024) };
      const fn = jest.fn().mockResolvedValue({ data: {}, httpStatus: 200 });

      await service.call(largePayload, fn, BASE_OPTIONS);

      const event = drainEnqueue.mock.calls[0][0];
      expect(event.payloadTruncated).toBe(true);
      expect(Buffer.byteLength(event.requestPayload, 'utf8')).toBeLessThanOrEqual(
        512 * 1024 + 20,
      );
    });
  });
});
