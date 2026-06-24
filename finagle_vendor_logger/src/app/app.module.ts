import { Module } from '@nestjs/common';
import { VendorLoggerModule } from '../vendor-logger.module';
import { VendorLoggerController } from './vendor-logger.controller';

@Module({
  imports: [
    VendorLoggerModule.forRoot({
      sqsQueueUrl: process.env.VENDOR_ARCHIVE_SQS_URL!,
      // region of the target SQS queue — must match the queue's region
      // (staging = ap-south-2, prod = ap-south-1). Set via AWS_REGION in the env file.
      sqsRegion: process.env.AWS_REGION ?? 'ap-south-2',
      serviceName: process.env.SERVICE_NAME ?? 'vendor-logger-svc',
      environment: process.env.NODE_ENV ?? 'staging',
      mobileHashSalt: process.env.MOBILE_HASH_SALT!,
      aadhaarHashSalt: process.env.AADHAAR_HASH_SALT!,
    }),
  ],
  controllers: [VendorLoggerController],
})
export class AppModule {}
