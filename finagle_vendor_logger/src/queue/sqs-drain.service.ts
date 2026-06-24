import { Injectable, Inject, OnModuleInit, OnModuleDestroy, Logger } from '@nestjs/common';
import {
  SQSClient,
  SendMessageBatchCommand,
  SendMessageBatchRequestEntry,
} from '@aws-sdk/client-sqs';
import { v4 as uuidv4 } from 'uuid';
import { RingBuffer } from './ring-buffer';
import {
  VENDOR_LOGGER_OPTIONS,
  VendorApiEvent,
  VendorApiEventWire,
  VendorLoggerModuleOptions,
  toWireEvent,
} from '../types';

const SQS_BATCH_LIMIT = 10;
const MAX_DRAIN_PER_TICK = 100;
const SQS_MAX_MSG_BYTES = 256 * 1024;

@Injectable()
export class SqsDrainService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(SqsDrainService.name);
  private readonly sqs: SQSClient;
  private readonly buffer: RingBuffer<VendorApiEvent>;
  private readonly queueUrl: string;
  private readonly drainIntervalMs: number;
  private drainTimer: NodeJS.Timeout | null = null;
  private draining = false;
  private consecutiveFailures = 0;
  private backoffUntil = 0;
  private currentDrain: Promise<void> | null = null;

  constructor(@Inject(VENDOR_LOGGER_OPTIONS) opts: VendorLoggerModuleOptions) {
    this.queueUrl = opts.sqsQueueUrl;
    this.drainIntervalMs = opts.drainIntervalMs ?? 100;
    this.sqs = new SQSClient({ region: opts.sqsRegion });
    this.buffer = new RingBuffer<VendorApiEvent>(opts.ringBufferSize ?? 5000);
  }

  onModuleInit(): void {
    this.drainTimer = setInterval(() => {
      this.currentDrain = this.drainOnce().catch((err) =>
        this.logger.error('Unhandled drain error', err),
      );
    }, this.drainIntervalMs);
    this.drainTimer.unref?.();
  }

  async onModuleDestroy(): Promise<void> {
    if (this.drainTimer) clearInterval(this.drainTimer);
    // Wait for any timer-triggered drain that is already in flight
    if (this.currentDrain) await this.currentDrain.catch(() => {});
    // Final flush of whatever remains in the buffer
    await this.drainOnce();
    this.sqs.destroy();
  }

  enqueue(event: VendorApiEvent): void {
    const dropped = this.buffer.push(event);
    if (dropped) {
      this.logger.warn(
        `Ring buffer full (capacity=${this.buffer.maxCapacity}) — oldest event dropped`,
      );
    }
  }

  get bufferSize(): number {
    return this.buffer.size;
  }

  private async drainOnce(): Promise<void> {
    if (this.draining || this.buffer.size === 0 || Date.now() < this.backoffUntil) return;
    this.draining = true;
    // Drain BEFORE try so we can re-enqueue on failure without the lock held
    const events = this.buffer.drain(MAX_DRAIN_PER_TICK);
    try {
      if (events.length === 0) return;
      await this.sendBatches(events);
      this.consecutiveFailures = 0;
    } catch (err) {
      this.consecutiveFailures++;
      // Cap backoff at 30s; base 500ms doubles per failure: 500, 1000, 2000, 4000 … 30000
      const backoffMs = Math.min(500 * 2 ** this.consecutiveFailures, 30_000);
      this.backoffUntil = Date.now() + backoffMs;
      // Re-enqueue so events aren't lost on transient SQS failure.
      // Oldest events may be dropped if the buffer filled while we were draining — acceptable per NFR10.
      for (const e of events) this.buffer.push(e);
      this.logger.error(
        `SQS drain failed (attempt ${this.consecutiveFailures}) — backing off ${backoffMs}ms`,
        err,
      );
    } finally {
      this.draining = false;
    }
  }

  private async sendBatches(events: VendorApiEvent[]): Promise<void> {
    for (let i = 0; i < events.length; i += SQS_BATCH_LIMIT) {
      const batch = events.slice(i, i + SQS_BATCH_LIMIT);
      const entries: SendMessageBatchRequestEntry[] = batch.map((evt) => ({
        Id: uuidv4().replace(/-/g, ''),
        MessageBody: this.safeMsgBody(evt),
      }));
      const result = await this.sqs.send(
        new SendMessageBatchCommand({ QueueUrl: this.queueUrl, Entries: entries }),
      );
      if (result.Failed?.length) {
        this.logger.error(
          `SQS batch partial failure: ${result.Failed.length} messages rejected`,
          result.Failed,
        );
      }
    }
  }

  private safeMsgBody(evt: VendorApiEvent): string {
    // The wire contract is snake_case, 1:1 with ClickHouse columns (CONVENTIONS.md §1).
    const wire = toWireEvent(evt);
    const body = JSON.stringify(wire);
    if (Buffer.byteLength(body, 'utf8') <= SQS_MAX_MSG_BYTES) return body;
    // Strip payloads to stay under 256KB — metadata is preserved for ClickHouse indexing
    const stripped: VendorApiEventWire = {
      ...wire,
      request_payload: '[OVERSIZED]',
      response_payload: '[OVERSIZED]',
      payload_truncated: true,
    };
    return JSON.stringify(stripped);
  }
}
