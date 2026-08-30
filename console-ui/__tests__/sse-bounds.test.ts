import { describe, expect, it } from "vitest";
import { readSsePayloads } from "@/lib/chat/sse";

async function payloads(chunks: Uint8Array[], limit: number): Promise<string[]> {
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
  const values: string[] = [];
  for await (const value of readSsePayloads(stream.getReader(), limit)) values.push(value);
  return values;
}

describe("bounded SSE parsing", () => {
  it("parses an event split across transport chunks", async () => {
    const encoder = new TextEncoder();
    await expect(payloads([
      encoder.encode("data: {\"cipher"),
      encoder.encode("text\":\"ok\"}\n\n"),
    ], 64)).resolves.toEqual(["{\"ciphertext\":\"ok\"}"]);
  });

  it("rejects a line before unbounded buffering or JSON parsing", async () => {
    const oversized = new TextEncoder().encode("data: " + "a".repeat(65));
    await expect(payloads([oversized], 64)).rejects.toThrow(
      "SSE line exceeds private-v2 byte limit",
    );
  });
});
