import { isHardwareSample, type HardwareSample } from '../shared/hardware';
import { frameData, splitFrames } from './sse';

// A frame carries one ~1 KB sample; anything far larger is not ours.
const maxBufferedBytes = 256_000;
// The runtime closes each stream after 120 one-second frames.
const streamTimeoutMs = 150_000;
const reconnectMs = 250;
const retryMs = 2000;

export function hardwareFrame(frame: string): HardwareSample | undefined {
  if (!frame.split('\n').includes('event: hardware')) return undefined;
  const data = frameData(frame);
  if (data === undefined) return undefined;
  try {
    const value: unknown = JSON.parse(data);
    return isHardwareSample(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });

// Reference-counted hardware stream: connected while at least one renderer
// subscription is held, so the runtime samples only while someone is looking.
export class HardwareWatch {
  private subscribers = 0;
  private controller?: AbortController;

  constructor(
    private open: (signal: AbortSignal) => Promise<Response>,
    private publish: (sample: HardwareSample) => void,
  ) {}

  get active() {
    return !!this.controller;
  }

  acquire() {
    this.subscribers += 1;
    if (!this.controller) {
      this.controller = new AbortController();
      void this.run(this.controller.signal);
    }
  }

  release() {
    this.subscribers = Math.max(0, this.subscribers - 1);
    if (this.subscribers === 0) this.stop();
  }

  // A reloaded or crashed renderer cannot release what it held.
  reset() {
    this.subscribers = 0;
    this.stop();
  }

  private stop() {
    this.controller?.abort();
    this.controller = undefined;
  }

  private async run(signal: AbortSignal) {
    while (!signal.aborted) {
      let delay = retryMs;
      try {
        const response = await this.open(
          AbortSignal.any([signal, AbortSignal.timeout(streamTimeoutMs)]),
        );
        if (!response.ok || !response.body) throw new Error('Hardware stream unavailable');
        await this.read(response.body.getReader(), signal);
        delay = reconnectMs;
      } catch {}
      if (!signal.aborted) await sleep(delay, signal);
    }
  }

  private async read(reader: ReadableStreamDefaultReader<Uint8Array>, signal: AbortSignal) {
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      if (buffer.length > maxBufferedBytes) {
        await reader.cancel();
        throw new Error('Hardware event too large');
      }
      const { frames, rest } = splitFrames(buffer);
      buffer = rest;
      for (const frame of frames) {
        const sample = hardwareFrame(frame);
        if (sample && !signal.aborted) this.publish(sample);
      }
    }
  }
}
