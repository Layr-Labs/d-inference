// Server-Sent-Events transport helpers. This layer only does byte→line→
// `data:` payload extraction; the semantic handling (unsealing, JSON parsing,
// [DONE]/receipt/delta routing) lives in stream.ts.

/**
 * Async-iterate the `data:` payloads of an SSE response body, buffering across
 * chunk boundaries. Yields the text after the `data: ` prefix for each event;
 * blank lines and non-data lines are skipped.
 */
export async function* readSsePayloads(
  reader: ReadableStreamDefaultReader<Uint8Array>,
): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  let buffer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || !trimmed.startsWith("data: ")) continue;
      yield trimmed.slice(6);
    }
  }
}
