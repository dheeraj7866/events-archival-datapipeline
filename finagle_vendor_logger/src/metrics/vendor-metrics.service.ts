import { Injectable, Inject } from '@nestjs/common';
import { Counter, Histogram, Registry, register } from 'prom-client';
import { VENDOR_LOGGER_OPTIONS, VendorLoggerModuleOptions } from '../types';

function httpStatusBand(code: number): string {
  if (code === 0)   return 'no_response';
  if (code < 200)   return '1xx';
  if (code < 300)   return '2xx';
  if (code < 400)   return '3xx';
  if (code < 500)   return '4xx';
  return '5xx';
}

@Injectable()
export class VendorMetricsService {
  private readonly callCounter: Counter<string>;
  private readonly latencyHistogram: Histogram<string>;

  constructor(@Inject(VENDOR_LOGGER_OPTIONS) opts: VendorLoggerModuleOptions) {
    const prefix = opts.metricsPrefix ?? 'vendor_api';
    const registry: Registry = register;

    this.callCounter = this.getOrCreate(
      () =>
        new Counter({
          name: `${prefix}_calls_total`,
          help: 'Total vendor API calls partitioned by vendor, endpoint, and outcome status',
          labelNames: ['vendor_id', 'endpoint', 'status', 'http_status'] as const,
          registers: [registry],
        }),
      `${prefix}_calls_total`,
      registry,
    ) as Counter<string>;

    this.latencyHistogram = this.getOrCreate(
      () =>
        new Histogram({
          name: `${prefix}_latency_ms`,
          help: 'Vendor API call duration in milliseconds',
          labelNames: ['vendor_id', 'endpoint', 'status'] as const,
          buckets: [50, 100, 200, 500, 1000, 2000, 5000],
          registers: [registry],
        }),
      `${prefix}_latency_ms`,
      registry,
    ) as Histogram<string>;
  }

  recordCall(opts: {
    vendorId: string;
    endpoint: string;
    status: string;
    httpStatus: number;
    latencyMs: number;
  }): void {
    const { vendorId, endpoint, status, httpStatus, latencyMs } = opts;
    const base = { vendor_id: vendorId, endpoint, status };
    this.callCounter.inc({ ...base, http_status: httpStatusBand(httpStatus) });
    this.latencyHistogram.observe(base, latencyMs);
  }

  private getOrCreate(
    factory: () => Counter<string> | Histogram<string>,
    name: string,
    registry: Registry,
  ): Counter<string> | Histogram<string> {
    try {
      return factory();
    } catch {
      return registry.getSingleMetric(name) as Counter<string> | Histogram<string>;
    }
  }
}
