import { describe, expect, it, vi } from 'vitest';
import { HardwareWatch, hardwareFrame } from '../src/main/hardware';
import { frameData, splitFrames } from '../src/main/sse';
import { previewHardwareSample } from '../src/renderer/previewHardware';

const sample = previewHardwareSample(1_790_000_000, true);
const frame = (value: unknown, event = 'hardware') =>
  `event: ${event}\ndata: ${JSON.stringify(value)}\n\n`;

// A live SSE body the test writes into, like the runtime's chunked response.
function stream() {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start: (c) => (controller = c) });
  const encoder = new TextEncoder();
  return {
    response: new Response(body, { headers: { 'Content-Type': 'text/event-stream' } }),
    write: (text: string) => controller.enqueue(encoder.encode(text)),
    close: () => controller.close(),
  };
}

describe('hardware frames', () => {
  it('splits complete frames and keeps the partial tail', () => {
    expect(splitFrames('a\n\nb\n\nc')).toEqual({ frames: ['a', 'b'], rest: 'c' });
    expect(splitFrames('partial')).toEqual({ frames: [], rest: 'partial' });
  });

  it('reads the data payload and skips frames without one', () => {
    expect(frameData('event: state\ndata: {"a":1}')).toBe('{"a":1}');
    expect(frameData(': keepalive')).toBeUndefined();
  });

  it('accepts only well-formed hardware events', () => {
    expect(hardwareFrame(frame(sample).trim())).toEqual(sample);
    expect(hardwareFrame(frame(sample, 'state').trim())).toBeUndefined();
    expect(hardwareFrame('event: hardware\ndata: {not json')).toBeUndefined();
    expect(hardwareFrame(frame({ ...sample, cpu: { load: ['high'] } }).trim())).toBeUndefined();
    expect(hardwareFrame(frame({ sampled_at: 1 }).trim())).toBeUndefined();
  });
});

describe('HardwareWatch', () => {
  it('opens one stream for any number of subscribers and closes after the last', async () => {
    const signals: AbortSignal[] = [];
    const open = vi.fn((signal: AbortSignal) => {
      signals.push(signal);
      return new Promise<Response>(() => {});
    });
    const watch = new HardwareWatch(open, () => {});
    watch.acquire();
    watch.acquire();
    expect(open).toHaveBeenCalledTimes(1);
    watch.release();
    expect(watch.active).toBe(true);
    expect(signals[0].aborted).toBe(false);
    watch.release();
    expect(watch.active).toBe(false);
    expect(signals[0].aborted).toBe(true);
    // Extra releases from a stale renderer cannot go negative and block the next subscriber.
    watch.release();
    watch.acquire();
    expect(open).toHaveBeenCalledTimes(2);
    watch.reset();
    expect(signals[1].aborted).toBe(true);
  });

  it('publishes frames split across chunks and reconnects when the stream ends', async () => {
    const first = stream();
    const second = stream();
    const open = vi
      .fn<(signal: AbortSignal) => Promise<Response>>()
      .mockResolvedValueOnce(first.response)
      .mockResolvedValueOnce(second.response)
      .mockReturnValue(new Promise(() => {}));
    const published: unknown[] = [];
    const watch = new HardwareWatch(open, (value) => published.push(value));
    watch.acquire();
    const text = frame(sample);
    first.write(text.slice(0, 40));
    first.write(text.slice(40) + frame(sample, 'state'));
    await vi.waitFor(() => expect(published).toEqual([sample]));
    first.close();
    await vi.waitFor(() => expect(open).toHaveBeenCalledTimes(2), { timeout: 2000 });
    second.write(frame({ ...sample, sampled_at: sample.sampled_at + 1 }));
    await vi.waitFor(() => expect(published).toHaveLength(2));
    watch.release();
  });

  it('drops an oversized stream and retries', async () => {
    vi.useFakeTimers();
    try {
      const huge = stream();
      const open = vi
        .fn<(signal: AbortSignal) => Promise<Response>>()
        .mockResolvedValueOnce(huge.response)
        .mockReturnValue(new Promise(() => {}));
      const published: unknown[] = [];
      const watch = new HardwareWatch(open, (value) => published.push(value));
      watch.acquire();
      huge.write('x'.repeat(300_000));
      await vi.advanceTimersByTimeAsync(2500);
      expect(open).toHaveBeenCalledTimes(2);
      expect(published).toEqual([]);
      watch.release();
    } finally {
      vi.useRealTimers();
    }
  });
});
