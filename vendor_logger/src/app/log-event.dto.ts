import { LoanLifecycleStage, VendorStatus } from '../types';

export class LogEventDto {
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
  requestPayload: unknown;
  responsePayload: unknown;
  httpStatus: number;
  latencyMs: number;
  status: VendorStatus;
  errorCode?: string;
  errorMessage?: string;
}
