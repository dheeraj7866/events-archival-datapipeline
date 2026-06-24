export const VENDOR_LOGGER_OPTIONS = 'VENDOR_LOGGER_OPTIONS' as const;

export enum LoanLifecycleStage {
  LEAD = 'LEAD',
  SELFIE = 'SELFIE',
  KYC = 'KYC',
  PAN_AADHAAR_SEED = 'PAN_AADHAAR_SEED',
  LOCATION_BRE = 'LOCATION_BRE',
  BUREAU_BRE = 'BUREAU_BRE',
  BANK_BRE = 'BANK_BRE',
  REPEAT_BRE = 'REPEAT_BRE',
  UNDERWRITING = 'UNDERWRITING',
  DISBURSED = 'DISBURSED',
  REPAID = 'REPAID',
  OVERDUE = 'OVERDUE',
  CLOSED = 'CLOSED',
  WRITTEN_OFF = 'WRITTEN_OFF',
  LMS_QUERY = 'LMS_QUERY',
  PENNY_DROP = 'PENNY_DROP',
  LOAN_AGREEMENT = 'LOAN_AGREEMENT',
  DISBURSEMENT = 'DISBURSEMENT',
}

export enum VendorStatus {
  SUCCESS = 'SUCCESS',
  FAILURE = 'FAILURE',
  TIMEOUT = 'TIMEOUT',
  NETWORK_ERROR = 'NETWORK_ERROR',
  LOGGER_ERROR = 'LOGGER_ERROR',
}

export interface VendorApiEvent {
  schemaVersion: number;
  requestId: string;
  createdAt: string;
  service: string;
  environment: string;
  vendorId: string;
  endpoint: string;
  vendorRefId?: string;
  loanLifecycleStage: LoanLifecycleStage;
  loanApplicationNumber?: string;
  userId?: string;
  panMasked?: string;
  mobileHash?: string;
  mobileLast4?: string;
  aadhaarLast4Hash?: string;
  consentId?: string;
  status: VendorStatus;
  httpStatus: number;
  latencyMs: number;
  errorCode?: string;
  errorMessage?: string;
  requestPayload: string;
  responsePayload: string;
  payloadTruncated: boolean;
  requestHash: string;
}

export interface VendorCallResult<T> {
  data: T;
  httpStatus: number;
  vendorRefId?: string;
}

export interface VendorCallOptions {
  vendorId: string;
  endpoint: string;
  loanLifecycleStage: LoanLifecycleStage;
  loanApplicationNumber?: string;
  userId?: string;
  pan?: string;
  mobile?: string;
  aadhaarLast4?: string;
  consentId?: string;
  vendorRefId?: string;
}

export interface VendorLoggerModuleOptions {
  sqsQueueUrl: string;
  sqsRegion: string;
  serviceName: string;
  environment: string;
  mobileHashSalt: string;
  aadhaarHashSalt: string;
  ringBufferSize?: number;
  drainIntervalMs?: number;
  maxPayloadBytes?: number;
  metricsPrefix?: string;
  global?: boolean;
}

export interface VendorLoggerModuleAsyncOptions {
  global?: boolean;
  imports?: any[];
  inject?: any[];
  useFactory: (
    ...args: any[]
  ) => Promise<VendorLoggerModuleOptions> | VendorLoggerModuleOptions;
}
