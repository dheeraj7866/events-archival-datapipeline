/**
 * Stateless deep-scanner that redacts PII from arbitrary vendor request/response
 * payloads before they are stored in SQS → S3 → ClickHouse.
 *
 * Strategy (applied in order):
 *   1. Key-name matching — normalises camelCase/snake_case/kebab-case and checks
 *      against known PII field name sets.
 *   2. Value-pattern fallback — for fields with unexpected names, regex patterns
 *      catch Indian mobile numbers, PAN, email, and 12-digit Aadhaar sequences.
 *
 * The stored payload is redacted; the requestHash in VendorApiEvent is computed
 * from the ORIGINAL payload (pre-redaction) to preserve audit chain of custody.
 */

// ─── Key-name sets (normalised: lowercase, separators stripped) ──────────────

const MOBILE_KEYS = new Set([
  'mobile', 'mobileno', 'mobilenumber', 'mobilenum',
  'phone', 'phoneno', 'phonenumber', 'phonenum',
  'contactno', 'contactnumber', 'contact', 'cellphone', 'cell',
  'whatsapp', 'whatsappno',
]);

const PAN_KEYS = new Set([
  'pan', 'pannumber', 'panno', 'pancard',
  'permanentaccountnumber', 'incometaxid',
]);

const EMAIL_KEYS = new Set([
  'email', 'emailid', 'emailaddress', 'mail',
]);

const ACCOUNT_KEYS = new Set([
  'accountno', 'accountnumber', 'bankaccount', 'accno', 'accountnum',
  'bankaccountno', 'bankaccountnumber', 'beneficiaryaccount',
  'beneficiaryaccountno', 'debitaccount', 'creditaccount',
]);

const AADHAAR_KEYS = new Set([
  'aadhaar', 'aadhar', 'aadhaarno', 'aadharno', 'aadhaarnumber',
  'adhaarnumber', 'uid', 'uidai',
]);

// ─── Value patterns ───────────────────────────────────────────────────────────

// Indian mobile: optional +91/91/0 prefix + 10 digits starting with 6-9
const MOBILE_RE = /^(\+91|91|0)?[6-9]\d{9}$/;
// PAN: 5 alpha + 4 digits + 1 alpha
const PAN_RE = /^[A-Z]{5}[0-9]{4}[A-Z]$/i;
// Email
const EMAIL_RE = /^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/;
// 12 consecutive digits (Aadhaar) — catches formatted XXXX XXXX XXXX too
const AADHAAR_RE_TEST    = /\b\d{4}\s?\d{4}\s?\d{4}\b/;
const AADHAAR_RE_REPLACE = /\b\d{4}\s?\d{4}\s?\d{4}\b/g;

// ─── Public API ───────────────────────────────────────────────────────────────

export class PayloadRedactor {
  private constructor() {}

  static redact(payload: unknown): unknown {
    return redactNode(payload, new WeakSet());
  }
}

// ─── Internal recursion ───────────────────────────────────────────────────────

function redactNode(node: unknown, seen: WeakSet<object>): unknown {
  if (node === null || node === undefined) return node;

  if (typeof node === 'string') return redactStringByPattern(node);
  if (typeof node !== 'object') return node;

  if (seen.has(node as object)) return '[CIRCULAR]';
  seen.add(node as object);

  if (Array.isArray(node)) {
    return node.map((item) => redactNode(item, seen));
  }

  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(node as Record<string, unknown>)) {
    result[key] = redactByKey(key, value, seen);
  }
  return result;
}

function redactByKey(key: string, value: unknown, seen: WeakSet<object>): unknown {
  const norm = normaliseKey(key);

  if (typeof value === 'string') {
    if (AADHAAR_KEYS.has(norm)) return '[AADHAAR_REDACTED]';
    if (MOBILE_KEYS.has(norm))  return maskMobile(value);
    if (PAN_KEYS.has(norm))     return maskPan(value);
    if (EMAIL_KEYS.has(norm))   return maskEmail(value);
    if (ACCOUNT_KEYS.has(norm)) return maskAccount(value);
    // Unknown key — fall through to pattern-based scan
    return redactStringByPattern(value);
  }

  // Recurse into nested objects/arrays
  if (typeof value === 'object' && value !== null) {
    return redactNode(value, seen);
  }

  return value;
}

function redactStringByPattern(value: string): string {
  // Aadhaar — highest priority, fully redact
  if (AADHAAR_RE_TEST.test(value)) {
    return value.replace(AADHAAR_RE_REPLACE, '[AADHAAR_REDACTED]');
  }

  const trimmed = value.replace(/\s/g, '');
  if (MOBILE_RE.test(trimmed)) return maskMobile(value);
  if (PAN_RE.test(value.trim())) return maskPan(value.trim());
  if (EMAIL_RE.test(value.trim())) return maskEmail(value.trim());

  return value;
}

// ─── Masking helpers ──────────────────────────────────────────────────────────

export function maskMobile(mobile: string): string {
  const digits = mobile.replace(/\D/g, '');
  if (digits.length < 4) return '***';
  return '*'.repeat(digits.length - 4) + digits.slice(-4);
}

export function maskPan(pan: string): string {
  const p = pan.trim();
  if (p.length < 6) return p;
  return p.substring(0, 3) + '*'.repeat(p.length - 6) + p.substring(p.length - 3);
}

export function maskEmail(email: string): string {
  const at = email.indexOf('@');
  if (at < 0) return '***@***';
  const local = email.substring(0, at);
  const domain = email.substring(at + 1);
  const maskedLocal =
    local.length <= 2
      ? '*'.repeat(local.length)
      : local[0] + '*'.repeat(local.length - 2) + local[local.length - 1];
  return `${maskedLocal}@${domain}`;
}

export function maskAccount(account: string): string {
  const digits = account.replace(/\D/g, '');
  if (digits.length <= 4) return '****';
  return '*'.repeat(digits.length - 4) + digits.slice(-4);
}

function normaliseKey(key: string): string {
  return key.toLowerCase().replace(/[_\-\s]/g, '');
}
