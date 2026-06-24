import { Controller, Post, Body, HttpCode, Logger } from '@nestjs/common';
import { v4 as uuidv4 } from 'uuid';
import { VendorHttpService } from '../http/vendor-http.service';
import { VendorCallOptions } from '../types';
import { LogEventDto } from './log-event.dto';

@Controller()
export class VendorLoggerController {
  private readonly logger = new Logger(VendorLoggerController.name);

  constructor(private readonly vendorHttp: VendorHttpService) {}

  @Post('log')
  @HttpCode(202)
  log(@Body() dto: LogEventDto): void {
    try {
      const options: VendorCallOptions = {
        vendorId: dto.vendorId,
        endpoint: dto.endpoint,
        loanLifecycleStage: dto.loanLifecycleStage,
        loanApplicationNumber: dto.loanApplicationNumber,
        userId: dto.userId,
        pan: dto.pan,
        mobile: dto.mobile,
        aadhaarLast4: dto.aadhaarLast4,
        consentId: dto.consentId,
        vendorRefId: dto.vendorRefId,
      };

      this.vendorHttp.logDirect({
        requestId: uuidv4(),
        createdAt: new Date().toISOString(),
        requestPayload: dto.requestPayload,
        responsePayload: dto.responsePayload,
        httpStatus: dto.httpStatus,
        latencyMs: dto.latencyMs,
        status: dto.status,
        errorCode: dto.errorCode,
        errorMessage: dto.errorMessage,
        vendorRefId: dto.vendorRefId,
        options,
      });

      // Per-request visibility — metadata only, never payloads (PII policy).
      this.logger.log(
        `accepted vendor=${dto.vendorId} endpoint=${dto.endpoint} stage=${dto.loanLifecycleStage} ` +
          `status=${dto.status} http=${dto.httpStatus} latencyMs=${dto.latencyMs}`,
      );
    } catch (err) {
      // fail-open: never let a logger failure surface as an HTTP error
      this.logger.warn(
        `dropped event vendor=${dto.vendorId}: ${(err as Error)?.message ?? err}`,
      );
    }
  }
}
