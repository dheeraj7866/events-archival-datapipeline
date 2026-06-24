import { Injectable, Inject } from '@nestjs/common';
import { createHmac, createHash } from 'crypto';
import { VENDOR_LOGGER_OPTIONS, VendorLoggerModuleOptions } from '../types';
import { maskPan as maskPanUtil } from './payload-redactor';

@Injectable()
export class PiiRedactor {
  private readonly mobileHashSalt: string;
  private readonly aadhaarHashSalt: string;

  constructor(@Inject(VENDOR_LOGGER_OPTIONS) opts: VendorLoggerModuleOptions) {
    this.mobileHashSalt = opts.mobileHashSalt;
    this.aadhaarHashSalt = opts.aadhaarHashSalt;
  }

  maskPan(pan: string): string {
    return maskPanUtil(pan);
  }

  hashMobile(mobile: string): { hash: string; last4: string } {
    const e164 = this.normalizeE164(mobile);
    const hash = createHmac('sha256', this.mobileHashSalt).update(e164).digest('hex');
    return { hash, last4: e164.slice(-4) };
  }

  hashAadhaarLast4(last4: string): string {
    return createHmac('sha256', this.aadhaarHashSalt).update(last4).digest('hex');
  }

  hashPayload(payload: string): string {
    return createHash('sha256').update(payload).digest('hex');
  }

  private normalizeE164(mobile: string): string {
    const digits = mobile.replace(/\D/g, '');
    if (digits.length === 10) return `+91${digits}`;
    if (digits.length === 12 && digits.startsWith('91')) return `+${digits}`;
    if (digits.length === 13 && digits.startsWith('091')) return `+${digits.slice(1)}`;
    return `+${digits}`;
  }
}
