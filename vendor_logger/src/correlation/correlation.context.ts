import { AsyncLocalStorage } from 'async_hooks';

interface CorrelationStore {
  correlationId: string;
}

const storage = new AsyncLocalStorage<CorrelationStore>();

export const CorrelationContext = {
  run<T>(correlationId: string, fn: () => T): T {
    return storage.run({ correlationId }, fn);
  },

  get(): string {
    return storage.getStore()?.correlationId ?? 'unknown';
  },
};
