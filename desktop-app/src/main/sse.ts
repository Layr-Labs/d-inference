// Server-sent event streams from the runtime: the framing its state, hardware and cluster setup
// streams share, and the wait before a stream opens again.

// Splits complete frames off the front of `buffer`.
export function splitFrames(buffer: string): { frames: string[]; rest: string } {
  const frames: string[] = [];
  let end: number;
  while ((end = buffer.indexOf('\n\n')) >= 0) {
    frames.push(buffer.slice(0, end));
    buffer = buffer.slice(end + 2);
  }
  return { frames, rest: buffer };
}

// The frame's `data:` payload; undefined for frames without one, such as keepalive comments.
export const frameData = (frame: string) =>
  frame
    .split('\n')
    .find((line) => line.startsWith('data: '))
    ?.slice(6);

// An `event: <name>` frame's JSON, when `accept` takes it; undefined for any other frame, and for
// a payload that is unreadable or not what `accept` checks for.
export function eventPayload<T>(
  frame: string,
  name: string,
  accept: (value: unknown) => value is T,
): T | undefined {
  if (!frame.split('\n').includes(`event: ${name}`)) return undefined;
  const data = frameData(frame);
  if (data === undefined) return undefined;
  try {
    const value: unknown = JSON.parse(data);
    return accept(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

// Waits `ms`, or less when `signal` aborts first.
export const sleep = (ms: number, signal: AbortSignal) =>
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
