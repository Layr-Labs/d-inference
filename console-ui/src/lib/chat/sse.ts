// Server-Sent-Events transport helpers. This layer only does byte→line→
// `data:` payload extraction; the semantic handling (unsealing, JSON parsing,
// [DONE]/receipt/delta routing) lives in stream.ts.

/**
 * Async-iterate the `data:` payloads of an SSE response body, buffering across
 * chunk boundaries. Yields the text after the `data: ` prefix for each event;
 * blank lines and non-data lines are skipped.
 */
export const MAX_SSE_LINE_BYTES = 1024 * 1024;

export async function* readSsePayloads(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  maxLineBytes = MAX_SSE_LINE_BYTES,
): AsyncGenerator<string> {
  if (!Number.isSafeInteger(maxLineBytes) || maxLineBytes <= 0 || maxLineBytes > MAX_SSE_LINE_BYTES) {
    throw new Error("invalid SSE line byte limit");
  }
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const pending = new Uint8Array(maxLineBytes);
  let pendingBytes = 0;

  const append = (part: Uint8Array) => {
    if (part.length === 0) return;
    if (part.length > maxLineBytes - pendingBytes) {
      throw new Error("SSE line exceeds private-v2 byte limit");
    }
    pending.set(part, pendingBytes);
    pendingBytes += part.length;
  };

  const takeLine = (): string => {
    const line = decoder.decode(pending.subarray(0, pendingBytes));
    pendingBytes = 0;
    return line;
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    let start = 0;
    for (let index = 0; index < value.length; index++) {
      if (value[index] !== 0x0a) continue;
      append(value.subarray(start, index));
      const trimmed = takeLine().trim();
      if (trimmed.startsWith("data: ")) yield trimmed.slice(6);
      start = index + 1;
    }
    append(value.subarray(start));
  }
}
