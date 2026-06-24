import { RingBuffer } from '../src/queue/ring-buffer';

describe('RingBuffer', () => {
  it('rejects capacity < 1', () => {
    expect(() => new RingBuffer(0)).toThrow(RangeError);
  });

  it('returns items in FIFO order', () => {
    const buf = new RingBuffer<number>(5);
    buf.push(1);
    buf.push(2);
    buf.push(3);
    expect(buf.drain(3)).toEqual([1, 2, 3]);
  });

  it('tracks size correctly after push and drain', () => {
    const buf = new RingBuffer<number>(5);
    buf.push(1);
    buf.push(2);
    expect(buf.size).toBe(2);
    buf.drain(1);
    expect(buf.size).toBe(1);
  });

  it('isFull returns true when at capacity', () => {
    const buf = new RingBuffer<number>(2);
    buf.push(1);
    expect(buf.isFull).toBe(false);
    buf.push(2);
    expect(buf.isFull).toBe(true);
  });

  it('drain returns empty array when buffer is empty', () => {
    const buf = new RingBuffer<number>(3);
    expect(buf.drain(10)).toEqual([]);
  });

  it('drain clamps to available items', () => {
    const buf = new RingBuffer<number>(5);
    buf.push(10);
    buf.push(20);
    const result = buf.drain(100);
    expect(result).toEqual([10, 20]);
    expect(buf.size).toBe(0);
  });

  describe('overflow — drops oldest item', () => {
    it('drops the oldest item when buffer is full', () => {
      const buf = new RingBuffer<number>(3);
      buf.push(1);
      buf.push(2);
      buf.push(3);
      const dropped = buf.push(4);
      expect(dropped).toBe(true);
      expect(buf.size).toBe(3);
      expect(buf.drain(3)).toEqual([2, 3, 4]);
    });

    it('indicates no drop when buffer is not full', () => {
      const buf = new RingBuffer<number>(5);
      const dropped = buf.push(1);
      expect(dropped).toBe(false);
    });

    it('handles continuous overflow correctly', () => {
      const buf = new RingBuffer<number>(3);
      for (let i = 1; i <= 10; i++) buf.push(i);
      // Last 3 pushed: 8, 9, 10
      expect(buf.drain(3)).toEqual([8, 9, 10]);
    });
  });

  it('supports wrap-around when head crosses capacity boundary', () => {
    const buf = new RingBuffer<string>(3);
    buf.push('a');
    buf.push('b');
    buf.push('c');
    buf.drain(2);             // drains a, b → head=2
    buf.push('d');            // tail wraps: buf[0]='d'
    buf.push('e');            // buf[1]='e'
    expect(buf.drain(3)).toEqual(['c', 'd', 'e']);
  });
});
