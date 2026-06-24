import { Test } from '@nestjs/testing';
import { PiiRedactor } from '../src/pii/pii-redactor.service';
import { VendorLoggerModuleOptions } from '../src/types';

const OPTS: VendorLoggerModuleOptions = {
  sqsQueueUrl: 'https://sqs.ap-south-1.amazonaws.com/123/test',
  sqsRegion: 'ap-south-1',
  serviceName: 'test-svc',
  environment: 'test',
  mobileHashSalt: 'mobile-test-salt-32chars-padding!!',
  aadhaarHashSalt: 'aadhar-test-salt-32chars-padding!!',
};

async function buildRedactor(): Promise<PiiRedactor> {
  const module = await Test.createTestingModule({
    providers: [
      { provide: 'VENDOR_LOGGER_OPTIONS', useValue: OPTS },
      PiiRedactor,
    ],
  }).compile();
  return module.get(PiiRedactor);
}

describe('PiiRedactor', () => {
  let redactor: PiiRedactor;

  beforeAll(async () => {
    redactor = await buildRedactor();
  });

  describe('maskPan', () => {
    it('masks middle digits of a standard 10-char PAN', () => {
      expect(redactor.maskPan('ABCDE1234F')).toBe('ABC****34F');
    });

    it('returns the pan unchanged when shorter than 6 chars', () => {
      expect(redactor.maskPan('AB123')).toBe('AB123');
    });

    it('produces a string of the same length as input', () => {
      const pan = 'ABCDE1234F';
      expect(redactor.maskPan(pan)).toHaveLength(pan.length);
    });
  });

  describe('hashMobile', () => {
    it('produces a 64-char hex hash for a 10-digit mobile', () => {
      const { hash } = redactor.hashMobile('9876543210');
      expect(hash).toMatch(/^[a-f0-9]{64}$/);
    });

    it('normalizes +91 prefix before hashing', () => {
      const a = redactor.hashMobile('9876543210');
      const b = redactor.hashMobile('+919876543210');
      const c = redactor.hashMobile('919876543210');
      expect(a.hash).toBe(b.hash);
      expect(a.hash).toBe(c.hash);
    });

    it('returns correct last4 digits', () => {
      const { last4 } = redactor.hashMobile('9876543210');
      expect(last4).toBe('3210');
    });

    it('produces different hashes for different mobiles', () => {
      const a = redactor.hashMobile('9876543210');
      const b = redactor.hashMobile('9876543211');
      expect(a.hash).not.toBe(b.hash);
    });
  });

  describe('hashAadhaarLast4', () => {
    it('produces a 64-char hex hash', () => {
      const h = redactor.hashAadhaarLast4('1234');
      expect(h).toMatch(/^[a-f0-9]{64}$/);
    });

    it('is deterministic', () => {
      expect(redactor.hashAadhaarLast4('1234')).toBe(redactor.hashAadhaarLast4('1234'));
    });

    it('uses separate salt from mobile — different input same digits gives different output', () => {
      const mobileHash = redactor.hashMobile('99991234').hash;
      const aadhaarHash = redactor.hashAadhaarLast4('1234');
      expect(mobileHash).not.toBe(aadhaarHash);
    });
  });

  describe('hashPayload', () => {
    it('produces a 64-char SHA-256 hex string', () => {
      const h = redactor.hashPayload('{"pan":"ABCDE1234F"}');
      expect(h).toMatch(/^[a-f0-9]{64}$/);
    });

    it('is deterministic', () => {
      const payload = JSON.stringify({ key: 'value' });
      expect(redactor.hashPayload(payload)).toBe(redactor.hashPayload(payload));
    });
  });
});
