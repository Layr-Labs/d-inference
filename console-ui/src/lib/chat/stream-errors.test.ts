import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import nacl from "tweetnacl";
import { POST } from "@/app/api/chat/route";
import { clearCoordinatorKeyCache, setEncryptionEnabled } from "../encryption";
import type { StreamCallbacks } from "../api/types";
import { streamChat } from "./stream";

const encoder = new TextEncoder();
const key = nacl.box.keyPair();
const kid = "0123456789abcdef";
let payloads: string[];
let sealed: boolean;
let upstreamCalls: number;

function callbacks(): StreamCallbacks {
  return { onToken: vi.fn(), onThinking: vi.fn(), onMetrics: vi.fn(), onDone: vi.fn(), onError: vi.fn() };
}

function content(text: string): string {
  return JSON.stringify({ choices: [{ delta: { content: text } }] });
}

// The coordinator's WriteChatStreamTerminalError emits this payload after
// committing HTTP 200; the proxy must preserve it through the SSE transport.
function terminalError(type: string, message: string): string {
  return JSON.stringify({ error: { type, message } });
}

function sealEvent(payload: string, recipient: Uint8Array): string {
  const nonce = nacl.randomBytes(nacl.box.nonceLength);
  const ciphertext = nacl.box(new Uint8Array(encoder.encode(`data: ${payload}\n\n`)), nonce, recipient, key.secretKey);
  return Buffer.concat([nonce, ciphertext]).toString("base64");
}

beforeEach(() => {
  localStorage.clear();
  clearCoordinatorKeyCache();
  setEncryptionEnabled(false);
  sealed = false;
  upstreamCalls = 0;
  payloads = [];
  vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    if (url === "/api/encryption-key") {
      return Response.json({ kid, public_key: Buffer.from(key.publicKey).toString("base64"), algorithm: "x25519-nacl-box" });
    }
    if (url === "/api/chat") {
      return POST(new NextRequest("https://console.invalid/api/chat", { ...init, signal: init?.signal ?? undefined }));
    }
    expect(String(url)).toMatch(/\/v1\/chat\/completions$/);
    upstreamCalls++;
    let recipient: Uint8Array | undefined;
    if (sealed) {
      const envelope = JSON.parse(new TextDecoder().decode(init?.body as Uint8Array));
      recipient = new Uint8Array(Buffer.from(envelope.ephemeral_public_key, "base64"));
    }
    const bytes = encoder.encode(payloads.map(payload => `data: ${recipient ? sealEvent(payload, recipient) : payload}\n\n`).join(""));
    let offset = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (offset === bytes.length) {
          controller.close();
          return;
        }
        // Split JSON, UTF-8 and sealed envelopes across arbitrary network reads.
        const end = Math.min(offset + 7, bytes.length);
        controller.enqueue(bytes.subarray(offset, end));
        offset = end;
      },
    });
    return new Response(stream, { headers: { "content-type": "text/event-stream", ...(sealed ? { "x-eigen-sealed": "true" } : {}) } });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe.each([false, true])("chat terminal errors (sealed=%s)", encrypted => {
  beforeEach(() => {
    sealed = encrypted;
    setEncryptionEnabled(encrypted);
  });

  it.each([
    { type: "provider_error", message: "provider unavailable", prefix: [] },
    { type: "timeout", message: "request timed out", prefix: [content("Partial café response")] },
  ])("reports $type at EOF instead of a successful completion", async ({ type, message, prefix }) => {
    payloads = [...prefix, terminalError(type, message)];
    const cb = callbacks();
    const usage = vi.fn();
    window.addEventListener("darkbloom-promotion-usage", usage);
    try {
      await streamChat([{ role: "user", content: "hello" }], "fixture-model", cb);
      expect(upstreamCalls).toBe(1);
      expect.soft(cb.onError).toHaveBeenCalledExactlyOnceWith(`Stream failed: ${message}`);
      expect.soft(cb.onDone).not.toHaveBeenCalled();
      expect(cb.onToken).toHaveBeenCalledTimes(prefix.length);
      if (prefix.length) expect(cb.onToken).toHaveBeenCalledWith("Partial café response");
      expect(usage).toHaveBeenCalledTimes(1);
    } finally {
      window.removeEventListener("darkbloom-promotion-usage", usage);
    }
  });

  it("stops at the first error even when more content and DONE follow", async () => {
    payloads = [terminalError("provider_error", "first failure"), content("must not be delivered"), terminalError("timeout", "second failure"), "[DONE]"];
    const cb = callbacks();
    await streamChat([{ role: "user", content: "hello" }], "fixture-model", cb);
    expect.soft(cb.onError).toHaveBeenCalledExactlyOnceWith("Stream failed: first failure");
    expect.soft(cb.onToken).not.toHaveBeenCalled();
    expect.soft(cb.onDone).not.toHaveBeenCalled();
  });

  it("reports an error event without a usable message", async () => {
    payloads = [JSON.stringify({ error: { type: "provider_error" } }), "[DONE]"];
    const cb = callbacks();
    await streamChat([{ role: "user", content: "hello" }], "fixture-model", cb);
    expect.soft(cb.onError).toHaveBeenCalledExactlyOnceWith("Stream failed: the request could not be completed");
    expect.soft(cb.onDone).not.toHaveBeenCalled();
  });

  it("preserves successful content, reasoning, receipts and DONE", async () => {
    payloads = [
      "not-json",
      JSON.stringify({ choices: [{ delta: { reasoning_content: "Thinking" } }] }),
      content('The word "error" is ordinary content.'),
      JSON.stringify({ se_signature: "fixture-signature", response_hash: "fixture-hash" }),
      "[DONE]",
    ];
    const cb = callbacks();
    await streamChat([{ role: "user", content: "hello" }], "fixture-model", cb);
    expect(cb.onError).not.toHaveBeenCalled();
    expect(cb.onThinking).toHaveBeenCalledWith("Thinking");
    expect(cb.onToken).toHaveBeenCalledWith('The word "error" is ordinary content.');
    expect(cb.onDone).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ seSignature: "fixture-signature", responseHash: "fixture-hash" }),
      expect.objectContaining({ tokenCount: 2 }),
    );
  });
});
