// Server-sent event framing shared by the runtime's state and hardware streams.

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
