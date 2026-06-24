import { DynamicModule, Module } from '@nestjs/common';
import {
  VENDOR_LOGGER_OPTIONS,
  VendorLoggerModuleAsyncOptions,
  VendorLoggerModuleOptions,
} from './types';
import { CorrelationMiddleware } from './correlation/correlation.middleware';
import { PiiRedactor } from './pii/pii-redactor.service';
import { SqsDrainService } from './queue/sqs-drain.service';
import { VendorMetricsService } from './metrics/vendor-metrics.service';
import { VendorHttpService } from './http/vendor-http.service';

const CORE_PROVIDERS = [
  PiiRedactor,
  SqsDrainService,
  VendorMetricsService,
  VendorHttpService,
  CorrelationMiddleware,
];

const EXPORTS = [VendorHttpService, CorrelationMiddleware, VendorMetricsService];

@Module({})
export class VendorLoggerModule {
  /**
   * Synchronous registration — use only when config is already available at
   * module load time (e.g. unit tests, local dev with hardcoded values).
   *
   * For production, prefer forRootAsync() so hash salts can be loaded from
   * AWS Secrets Manager before the module initialises.
   */
  static forRoot(options: VendorLoggerModuleOptions): DynamicModule {
    return {
      global: options.global ?? false,
      module: VendorLoggerModule,
      providers: [
        { provide: VENDOR_LOGGER_OPTIONS, useValue: options },
        ...CORE_PROVIDERS,
      ],
      exports: EXPORTS,
    };
  }

  /**
   * Async registration — the standard production pattern.
   *
   * Usage (identity-api app.module.ts):
   *
   *   VendorLoggerModule.forRootAsync({
   *     global: true,
   *     imports: [SecretsManagerModule],
   *     inject: [SecretsManagerService],
   *     useFactory: async (sm: SecretsManagerService) => ({
   *       sqsQueueUrl: process.env.VENDOR_ARCHIVE_SQS_URL!,
   *       sqsRegion: 'ap-south-1',
   *       serviceName: 'identity-api',
   *       environment: process.env.NODE_ENV!,
   *       mobileHashSalt:  await sm.getSecret('MOBILE_HASH_SALT'),
   *       aadhaarHashSalt: await sm.getSecret('AADHAAR_HASH_SALT'),
   *     }),
   *   })
   *
   * Requires app.enableShutdownHooks() in main.ts for graceful SQS drain on SIGTERM.
   */
  static forRootAsync(options: VendorLoggerModuleAsyncOptions): DynamicModule {
    return {
      global: options.global ?? false,
      module: VendorLoggerModule,
      imports: options.imports ?? [],
      providers: [
        {
          provide: VENDOR_LOGGER_OPTIONS,
          useFactory: options.useFactory,
          inject: options.inject ?? [],
        },
        ...CORE_PROVIDERS,
      ],
      exports: EXPORTS,
    };
  }
}
