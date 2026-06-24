import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app/app.module';

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule, {
    bodyParser: true,
  });
  app.use(require('express').json({ limit: '512kb' }));
  app.enableShutdownHooks();
  await app.listen(process.env.PORT ?? 3010);
}

bootstrap();
