import { SQSClient } from '@aws-sdk/client-sqs';
import { SqsDrainService } from '../src/queue/sqs-drain.service';
import {
  VENDOR_LOGGER_OPTIONS,
  LoanLifecycleStage,
  VendorApiEvent,
  VendorStatus,
} from '../src/types';

jest.mock('@aws-sdk/client-sqs', () => ({
  SQSClient: jest.fn(),
  SendMessageBatchCommand: jest.fn().mockImplementation((input) => input),
}));

const BASE_OPTS = {
  sqsQueueUrl: 'https://sqs.ap-south-1.amazonaws.com/123/test',
  sqsRegion: 'ap-south-1',
  serviceName: 'test-svc',
  environment: 'test',
  mobileHashSalt: 'test-salt',
  aadhaarHashSalt: 'test-salt',
  drainIntervalMs: 100,
  ringBufferSize: 50,
};

let eventSeq = 0;
function makeEvent(): VendorApiEvent {
  return {
    schemaVersion: 1,
    requestId: `req-${++eventSeq}`,
    createdAt: new Date().toISOString(),
    service: 'test-svc',
    environment: 'test',
    vendorId: 'karza',
    endpoint: '/v1/test',
    loanLifecycleStage: LoanLifecycleStage.KYC,
    status: VendorStatus.SUCCESS,
    httpStatus: 200,
    latencyMs: 50,
    requestPayload: '{}',
    responsePayload: '{}',
    payloadTruncated: false,
    requestHash: 'abc123',
  };
}

describe('SqsDrainService', () => {
  let sqsSend: jest.Mock;
  let sqsDestroy: jest.Mock;

  beforeEach(() => {
    eventSeq = 0;
    sqsSend = jest.fn();
    sqsDestroy = jest.fn();
    (SQSClient as jest.Mock).mockImplementation(() => ({
      send: sqsSend,
      destroy: sqsDestroy,
    }));
  });

  function createService(): SqsDrainService {
    return new SqsDrainService({ [VENDOR_LOGGER_OPTIONS]: BASE_OPTS, ...BASE_OPTS } as any);
  }

  // Direct drain call helper — bypasses the timer for unit tests
  async function drain(service: SqsDrainService): Promise<void> {
    return (service as any).drainOnce();
  }

  // ─── Re-enqueue on failure ────────────────────────────────────────────────

  describe('re-enqueue on SQS failure', () => {
    it('puts events back in the buffer when SQS throws', async () => {
      sqsSend.mockRejectedValue(new Error('SQS unavailable'));
      const service = createService();
      service.enqueue(makeEvent());

      await drain(service);

      expect(service.bufferSize).toBe(1);
    });

    it('attempts to send events on the next successful tick', async () => {
      sqsSend
        .mockRejectedValueOnce(new Error('SQS unavailable'))
        .mockResolvedValue({ Failed: [] });

      const service = createService();
      service.enqueue(makeEvent());

      jest.useFakeTimers();
      await drain(service);                    // fails → re-enqueued
      jest.setSystemTime(Date.now() + 1100);   // advance past 1st backoff
      await drain(service);                    // succeeds
      jest.useRealTimers();

      expect(sqsSend).toHaveBeenCalledTimes(2);
      expect(service.bufferSize).toBe(0);
    });
  });

  // ─── Exponential backoff ──────────────────────────────────────────────────

  describe('exponential backoff', () => {
    beforeEach(() => jest.useFakeTimers());
    afterEach(() => jest.useRealTimers());

    it('skips drain ticks within the backoff window after a failure', async () => {
      sqsSend.mockRejectedValue(new Error('SQS unavailable'));
      const service = createService();
      service.enqueue(makeEvent());

      await drain(service);               // first drain: fails, sets backoffUntil = now + 1000ms
      expect(sqsSend).toHaveBeenCalledTimes(1);

      service.enqueue(makeEvent());
      await drain(service);               // immediately within backoff → skipped
      expect(sqsSend).toHaveBeenCalledTimes(1);
    });

    it('resumes draining after the backoff window expires', async () => {
      sqsSend
        .mockRejectedValueOnce(new Error('SQS unavailable'))
        .mockResolvedValue({ Failed: [] });
      const service = createService();
      service.enqueue(makeEvent());

      await drain(service);               // fails → backoff = 1000ms (consecutiveFailures=1)
      expect(sqsSend).toHaveBeenCalledTimes(1);

      jest.setSystemTime(Date.now() + 1100);   // advance past 1000ms window
      await drain(service);               // should send now
      expect(sqsSend).toHaveBeenCalledTimes(2);
    });

    it('resets the failure counter after a successful send so next failure starts from 1s', async () => {
      sqsSend
        .mockRejectedValueOnce(new Error('SQS unavailable'))
        .mockResolvedValueOnce({ Failed: [] })
        .mockRejectedValueOnce(new Error('SQS unavailable'));
      const service = createService();

      service.enqueue(makeEvent());
      await drain(service);                    // fails (consecutiveFailures=1, backoff=1s)
      jest.setSystemTime(Date.now() + 1100);
      await drain(service);                    // succeeds → counter resets to 0

      service.enqueue(makeEvent());
      await drain(service);                    // fails again (consecutiveFailures=1, backoff=1s again)

      // 600ms later: still within the 1s backoff (not 2s — counter was reset)
      jest.setSystemTime(Date.now() + 600);
      service.enqueue(makeEvent());
      await drain(service);                    // should be blocked
      expect(sqsSend).toHaveBeenCalledTimes(3); // no 4th attempt
    });

    it('caps backoff at 30 seconds after sustained failures', async () => {
      sqsSend.mockRejectedValue(new Error('SQS unavailable'));
      const service = createService();

      // Drive 7 failures, advancing past each backoff each time
      for (let i = 1; i <= 7; i++) {
        service.enqueue(makeEvent());
        await drain(service);
        const thisBackoff = Math.min(500 * 2 ** i, 30_000);
        jest.setSystemTime(Date.now() + thisBackoff + 50);
      }
      // consecutiveFailures = 7 → next backoff = min(500 * 2^8, 30000) = 30000ms (cap)

      const callsBefore = sqsSend.mock.calls.length;
      service.enqueue(makeEvent());
      await drain(service);                       // fails → backoff set to 30s cap
      expect(sqsSend).toHaveBeenCalledTimes(callsBefore + 1);

      // 29s later: still within the 30s cap
      jest.setSystemTime(Date.now() + 29_000);
      await drain(service);
      expect(sqsSend).toHaveBeenCalledTimes(callsBefore + 1); // no new attempt

      // Advance past the cap
      jest.setSystemTime(Date.now() + 1_100);
      await drain(service);
      expect(sqsSend).toHaveBeenCalledTimes(callsBefore + 2); // resumed
    });
  });

  // ─── Shutdown safety ──────────────────────────────────────────────────────

  describe('onModuleDestroy', () => {
    it('flushes remaining buffer events before destroying the SQS client', async () => {
      sqsSend.mockResolvedValue({ Failed: [] });
      const service = createService();
      service.enqueue(makeEvent());
      service.enqueue(makeEvent());

      await service.onModuleDestroy();

      expect(sqsSend).toHaveBeenCalledTimes(1);
      expect(service.bufferSize).toBe(0);
      expect(sqsDestroy).toHaveBeenCalledTimes(1);
      // Ordering guarantee: send must complete before destroy
      expect(sqsSend.mock.invocationCallOrder[0]).toBeLessThan(
        sqsDestroy.mock.invocationCallOrder[0],
      );
    });

    it('calls sqs.destroy() even when the final drain fails', async () => {
      sqsSend.mockRejectedValue(new Error('SQS unavailable'));
      const service = createService();
      service.enqueue(makeEvent());

      await service.onModuleDestroy();

      expect(sqsDestroy).toHaveBeenCalledTimes(1);
    });

    it('waits for an in-flight timer drain to complete before destroying the client', async () => {
      jest.useFakeTimers();

      let resolveSend!: (v: unknown) => void;
      sqsSend.mockImplementation(() => new Promise((r) => { resolveSend = r; }));

      const service = createService();
      service.onModuleInit();
      service.enqueue(makeEvent());

      // Fire the interval callback synchronously — drain starts but SQS send hangs
      jest.advanceTimersByTime(100);

      // Begin shutdown while drain is still in-flight
      const destroyPromise = service.onModuleDestroy();
      expect(sqsDestroy).not.toHaveBeenCalled();  // must wait for in-flight send

      // Resolve the hanging SQS send
      resolveSend({ Failed: [] });
      await destroyPromise;

      expect(sqsDestroy).toHaveBeenCalledTimes(1);
      jest.useRealTimers();
    });
  });
});
