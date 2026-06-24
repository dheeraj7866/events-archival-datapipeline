import { PayloadRedactor, maskMobile, maskPan, maskEmail, maskAccount } from '../src/pii/payload-redactor';

describe('PayloadRedactor', () => {

  // ─── Masking helpers ───────────────────────────────────────────────────────

  describe('maskMobile', () => {
    it('masks all but last 4 digits', () => expect(maskMobile('9876543210')).toBe('******3210'));
    it('handles +91 prefix', ()         => expect(maskMobile('+919876543210')).toBe('********3210'));
    it('handles short input gracefully', () => expect(maskMobile('123')).toBe('***'));
  });

  describe('maskPan', () => {
    it('masks middle 4 chars of 10-char PAN', () => expect(maskPan('ABCDE1234F')).toBe('ABC****34F'));
    it('preserves first 3 and last 3 chars',   () => {
      const result = maskPan('PQRST5678U');
      expect(result.startsWith('PQR')).toBe(true);
      expect(result.endsWith('78U')).toBe(true);
    });
  });

  describe('maskEmail', () => {
    it('masks middle chars of local part, keeps domain', () => {
      expect(maskEmail('pratyush@gmail.com')).toBe('p******h@gmail.com');
    });
    it('handles single-char local part', () => expect(maskEmail('p@x.com')).toBe('*@x.com'));
    it('handles two-char local part',    () => expect(maskEmail('ab@x.com')).toBe('**@x.com'));
    it('handles missing @ gracefully',   () => expect(maskEmail('notanemail')).toBe('***@***'));
  });

  describe('maskAccount', () => {
    it('masks all but last 4 digits', () => expect(maskAccount('1234567890')).toBe('******7890'));
    it('handles short input',         () => expect(maskAccount('1234')).toBe('****'));
  });

  // ─── Key-name based redaction ──────────────────────────────────────────────

  describe('key-name matching — mobile', () => {
    const fields = ['mobile', 'mobileNo', 'mobile_no', 'phone', 'phoneNumber', 'contactNo'];
    it.each(fields)('redacts field key "%s"', (key) => {
      const result = PayloadRedactor.redact({ [key]: '9876543210' }) as Record<string, string>;
      expect(result[key]).toBe('******3210');
      expect(result[key]).not.toContain('9876');
    });
  });

  describe('key-name matching — PAN', () => {
    const fields = ['pan', 'panNumber', 'pan_number', 'panCard'];
    it.each(fields)('redacts field key "%s"', (key) => {
      const result = PayloadRedactor.redact({ [key]: 'ABCDE1234F' }) as Record<string, string>;
      expect(result[key]).toBe('ABC****34F');
    });
  });

  describe('key-name matching — email', () => {
    const fields = ['email', 'emailId', 'email_id', 'emailAddress'];
    it.each(fields)('redacts field key "%s"', (key) => {
      const result = PayloadRedactor.redact({ [key]: 'user@example.com' }) as Record<string, string>;
      expect(result[key]).toContain('@example.com');
      expect(result[key]).not.toBe('user@example.com');
    });
  });

  describe('key-name matching — account number', () => {
    const fields = ['accountNo', 'accountNumber', 'bankAccount', 'beneficiaryAccount'];
    it.each(fields)('redacts field key "%s"', (key) => {
      const result = PayloadRedactor.redact({ [key]: '1234567890' }) as Record<string, string>;
      expect(result[key]).toBe('******7890');
    });
  });

  describe('key-name matching — Aadhaar', () => {
    it('fully redacts aadhaar key', () => {
      const result = PayloadRedactor.redact({ aadhaar: '123412341234' }) as Record<string, string>;
      expect(result.aadhaar).toBe('[AADHAAR_REDACTED]');
    });
    it('fully redacts aadhar key (alternate spelling)', () => {
      const result = PayloadRedactor.redact({ aadhar: '1234 5678 9012' }) as Record<string, string>;
      expect(result.aadhar).toBe('[AADHAAR_REDACTED]');
    });
  });

  // ─── Value-pattern fallback (unknown key names) ────────────────────────────

  describe('value-pattern fallback', () => {
    it('detects and masks a 10-digit Indian mobile stored under unknown key', () => {
      const result = PayloadRedactor.redact({ customerContact: '9123456789' }) as Record<string, string>;
      expect(result.customerContact).toBe('******6789');
    });

    it('detects and masks PAN stored under unknown key', () => {
      const result = PayloadRedactor.redact({ taxId: 'LMNOP9012Q' }) as Record<string, string>;
      expect(result.taxId).toBe('LMN****12Q');
    });

    it('detects and masks email stored under unknown key', () => {
      const result = PayloadRedactor.redact({ userInfo: 'tech@ffspl.com' }) as Record<string, string>;
      expect(result.userInfo).toBe('t**h@ffspl.com');
    });

    it('redacts 12-digit Aadhaar sequence in a string value', () => {
      const result = PayloadRedactor.redact({ data: 'Aadhaar: 1234 5678 9012' }) as Record<string, string>;
      expect(result.data).toContain('[AADHAAR_REDACTED]');
      expect(result.data).not.toContain('1234 5678 9012');
    });

    it('leaves non-PII strings untouched', () => {
      const result = PayloadRedactor.redact({ loanId: 'LOAN-20260101-001' }) as Record<string, string>;
      expect(result.loanId).toBe('LOAN-20260101-001');
    });
  });

  // ─── Nested and array payloads ─────────────────────────────────────────────

  describe('nested objects', () => {
    it('recurses into nested objects', () => {
      const input = {
        applicant: {
          name: 'Pratyush Kumar',
          mobile: '9876543210',
          kyc: { pan: 'ABCDE1234F', email: 'p@ffspl.com' },
        },
      };
      const result = PayloadRedactor.redact(input) as any;
      expect(result.applicant.mobile).toBe('******3210');
      expect(result.applicant.kyc.pan).toBe('ABC****34F');
      expect(result.applicant.kyc.email).not.toBe('p@ffspl.com');
      expect(result.applicant.name).toBe('Pratyush Kumar'); // names not redacted
    });

    it('recurses into arrays', () => {
      const input = {
        contacts: [
          { mobile: '9000000001' },
          { mobile: '9000000002' },
        ],
      };
      const result = PayloadRedactor.redact(input) as any;
      expect(result.contacts[0].mobile).toBe('******0001');
      expect(result.contacts[1].mobile).toBe('******0002');
    });

    it('handles null and undefined values without throwing', () => {
      const input = { mobile: null, pan: undefined, email: '' };
      expect(() => PayloadRedactor.redact(input)).not.toThrow();
    });
  });

  // ─── Real-world vendor payload shapes ─────────────────────────────────────

  describe('Karza KYC response shape', () => {
    it('redacts mobile and PAN from Karza verify response', () => {
      const karzaResponse = {
        status: 200,
        result: {
          pan: 'ABCDE1234F',
          name: 'PRATYUSH KUMAR',
          dob: '1990-01-01',
          mobile: '9876543210',
          email: 'pratyush@example.com',
          aadhaarSeedingStatus: 'Y',
        },
        requestId: 'KARZA-REF-001',
      };
      const result = PayloadRedactor.redact(karzaResponse) as any;
      expect(result.result.pan).toBe('ABC****34F');
      expect(result.result.mobile).toBe('******3210');
      expect(result.result.email).not.toBe('pratyush@example.com');
      expect(result.result.name).toBe('PRATYUSH KUMAR');
      expect(result.status).toBe(200);
      expect(result.requestId).toBe('KARZA-REF-001');
    });
  });

  describe('Easebuzz disbursement request shape', () => {
    it('redacts account number from disbursement request', () => {
      const disburseReq = {
        amount: 5000000,
        beneficiaryAccount: '1234567890',
        beneficiaryName: 'PRATYUSH KUMAR',
        ifsc: 'HDFC0001234',
        mobile: '9876543210',
        txnNote: 'Loan disbursal LOAN-001',
      };
      const result = PayloadRedactor.redact(disburseReq) as any;
      expect(result.beneficiaryAccount).toBe('******7890');
      expect(result.mobile).toBe('******3210');
      expect(result.beneficiaryName).toBe('PRATYUSH KUMAR');
      expect(result.amount).toBe(5000000);
    });
  });

  describe('NSDL PAN-Aadhaar seeding request', () => {
    it('redacts PAN and masks aadhaar key', () => {
      const nsdlReq = {
        pan: 'PQRST5678U',
        aadhaar: '9876543212345',  // hypothetical if vendor sends it
        consentTimestamp: '2026-05-01T10:00:00Z',
      };
      const result = PayloadRedactor.redact(nsdlReq) as any;
      expect(result.pan).toBe('PQR****78U');
      expect(result.aadhaar).toBe('[AADHAAR_REDACTED]');
      expect(result.consentTimestamp).toBe('2026-05-01T10:00:00Z');
    });
  });

  // ─── Safety: circular reference, null top-level, non-objects ──────────────

  describe('edge cases', () => {
    it('handles circular reference without throwing', () => {
      const obj: any = { id: 'test' };
      obj.self = obj;
      expect(() => PayloadRedactor.redact(obj)).not.toThrow();
      const result = PayloadRedactor.redact(obj) as any;
      expect(result.self).toBe('[CIRCULAR]');
    });

    it('returns null as-is', ()      => expect(PayloadRedactor.redact(null)).toBeNull());
    it('returns undefined as-is', () => expect(PayloadRedactor.redact(undefined)).toBeUndefined());
    it('returns numbers as-is', ()   => expect(PayloadRedactor.redact(42)).toBe(42));
    it('returns booleans as-is', ()  => expect(PayloadRedactor.redact(true)).toBe(true));

    it('does not mutate the original object', () => {
      const original = { mobile: '9876543210', pan: 'ABCDE1234F' };
      PayloadRedactor.redact(original);
      expect(original.mobile).toBe('9876543210');
      expect(original.pan).toBe('ABCDE1234F');
    });
  });
});
