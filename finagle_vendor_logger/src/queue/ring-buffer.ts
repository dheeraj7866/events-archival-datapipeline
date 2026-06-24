export class RingBuffer<T> {
  private readonly buf: (T | undefined)[];
  private head = 0;
  private tail = 0;
  private count = 0;

  constructor(private readonly capacity: number) {
    if (capacity < 1) throw new RangeError('RingBuffer capacity must be >= 1');
    this.buf = new Array(capacity);
  }

  push(item: T): boolean {
    const dropped = this.count === this.capacity;
    this.buf[this.tail] = item;
    this.tail = (this.tail + 1) % this.capacity;
    if (dropped) {
      this.head = (this.head + 1) % this.capacity;
    } else {
      this.count++;
    }
    return dropped;
  }

  drain(max: number): T[] {
    const take = Math.min(max, this.count);
    const items: T[] = new Array(take);
    for (let i = 0; i < take; i++) {
      items[i] = this.buf[this.head] as T;
      this.buf[this.head] = undefined;
      this.head = (this.head + 1) % this.capacity;
    }
    this.count -= take;
    return items;
  }

  get size(): number {
    return this.count;
  }

  get isFull(): boolean {
    return this.count === this.capacity;
  }

  get maxCapacity(): number {
    return this.capacity;
  }
}
