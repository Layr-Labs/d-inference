import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import nacl from "tweetnacl";
import { streamChat } from "./stream";
import { POST } from "@/app/api/chat/route";
import { setEncryptionEnabled, SEALED_CONTENT_TYPE } from "../encryption";
import { toApiMessages } from "../chat-messages";
import type { ChatMessage, StreamCallbacks } from "../api/types";

const LIMIT = 16 * 1024 * 1024;
const MIB = 1024 * 1024;
const MODEL = "fixture-vision-model";
const encoder = new TextEncoder();
const key = nacl.box.keyPair();
let kid = "0123456789abcdef";
let keyCalls = 0;
let chatCalls = 0;
let upstreamCalls = 0;
let sentBody = "";
let sentHeaders: Headers;
let sentSignal: AbortSignal | null | undefined;
let openedBody = "";

function callbacks(): StreamCallbacks {
  return { onToken: vi.fn(), onThinking: vi.fn(), onMetrics: vi.fn(), onDone: vi.fn(), onError: vi.fn() };
}

function image(bytes: number): string {
  return `data:image/jpeg;base64,${Buffer.alloc(bytes).toString("base64")}`;
}

function requestJson(messages: ChatMessage[], model = MODEL): string {
  return JSON.stringify({ model, messages, stream: true, enable_thinking: true });
}

function textMessagesAtBytes(bytes: number): ChatMessage[] {
  const empty: ChatMessage[] = [{ role: "user", content: "" }];
  const overhead = encoder.encode(requestJson(empty)).byteLength;
  return [{ role: "user", content: "a".repeat(bytes - overhead) }];
}

function expectSizeError(cb: StreamCallbacks) {
  expect(cb.onError).toHaveBeenCalledTimes(1);
  expect(vi.mocked(cb.onError).mock.calls[0][0]).toMatch(/too large/i);
  expect(vi.mocked(cb.onError).mock.calls[0][0]).toMatch(/image|shorten|reduce/i);
  expect(vi.mocked(cb.onError).mock.calls[0][0]).not.toMatch(/encryption setup failed|disable.*encrypt/i);
  expect(cb.onDone).not.toHaveBeenCalled();
}

beforeEach(() => {
  localStorage.clear();
  setEncryptionEnabled(false);
  kid = "0123456789abcdef";
  keyCalls = chatCalls = upstreamCalls = 0;
  sentBody = openedBody = "";
  sentSignal = undefined;
  vi.stubGlobal("fetch", vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    if (url === "/api/encryption-key") {
      keyCalls++;
      return Response.json({ kid, public_key: Buffer.from(key.publicKey).toString("base64"), algorithm: "x25519-nacl-box" });
    }
    if (url === "/api/chat") {
      chatCalls++;
      sentBody = init?.body as string;
      sentHeaders = new Headers(init?.headers);
      sentSignal = init?.signal;
      // Run the real Next POST handler, including sealed byte pass-through.
      return POST(new NextRequest("https://console.invalid/api/chat", { ...init, signal: init?.signal ?? undefined }));
    }
    expect(String(url)).toMatch(/\/v1\/chat\/completions$/);
    upstreamCalls++;
    const actual = typeof init?.body === "string" ? init.body : new TextDecoder().decode(init?.body as Uint8Array);
    expect(actual).toBe(sentBody);
    if (sentHeaders.get("content-type") === SEALED_CONTENT_TYPE) {
      const envelope = JSON.parse(actual);
      const sealed = new Uint8Array(Buffer.from(envelope.ciphertext, "base64"));
      const pub = new Uint8Array(Buffer.from(envelope.ephemeral_public_key, "base64"));
      const opened = nacl.box.open(sealed.subarray(24), sealed.subarray(0, 24), pub, key.secretKey);
      expect(opened).not.toBeNull();
      openedBody = new TextDecoder().decode(opened!);
    }
    return new Response("data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("chat transport byte budget", () => {
  it.each([2, 4])("refuses %i accepted large images before any request", async (count) => {
    const bytes = count === 2 ? 7 * MIB : 10 * MIB;
    const messages = toApiMessages([{ role: "user", content: "describe", images: Array.from({ length: count }, () => image(bytes)) }]);
    expect(encoder.encode(requestJson(messages)).byteLength).toBeGreaterThan(LIMIT);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(chatCalls).toBe(0);
    expect(keyCalls).toBe(0);
    expectSizeError(cb);
  });

  it("preserves a valid single 10 MiB plaintext image, headers, and abort signal", async () => {
    const messages = toApiMessages([{ role: "user", content: "describe", images: [image(10 * MIB)] }]);
    localStorage.setItem("darkbloom_api_key", "fixture-only-key");
    const abort = new AbortController();
    const cb = callbacks();
    await streamChat(messages, MODEL, cb, abort.signal, { selfRoute: true });
    expect(chatCalls).toBe(1);
    expect(upstreamCalls).toBe(1);
    expect(sentBody).toBe(requestJson(messages));
    expect(sentHeaders.get("x-api-key")).toBe("fixture-only-key");
    expect(sentHeaders.get("x-darkbloom-route")).toBe("prefer");
    expect(sentSignal).toBe(abort.signal);
    expect(cb.onError).not.toHaveBeenCalled();
    expect(cb.onDone).toHaveBeenCalledTimes(1);
  });

  it.each([0, 1])("enforces the plaintext cap with %i extra byte", async (extra) => {
    const messages = textMessagesAtBytes(LIMIT + extra);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(chatCalls).toBe(extra === 0 ? 1 : 0);
    if (extra) expectSizeError(cb);
    else expect(encoder.encode(sentBody).byteLength).toBe(LIMIT);
  });

  it("counts UTF-8 history and options rather than JavaScript string length", async () => {
    const messages: ChatMessage[] = [
      { role: "system", content: "💡".repeat(3 * MIB) },
      { role: "user", content: "é".repeat(3 * MIB) },
    ];
    expect(requestJson(messages).length).toBeLessThan(LIMIT);
    expect(encoder.encode(requestJson(messages)).byteLength).toBeGreaterThan(LIMIT);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb, undefined, { enableThinking: false });
    expect(chatCalls).toBe(0);
    expectSizeError(cb);
  });

  it("refuses a 10 MiB image with sender encryption before fetching a key", async () => {
    setEncryptionEnabled(true);
    const messages = toApiMessages([{ role: "user", content: "describe", images: [image(10 * MIB)] }]);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(keyCalls).toBe(0);
    expect(chatCalls).toBe(0);
    expectSizeError(cb);
  });

  it("seals and forwards a valid small request with real NaCl and the real proxy", async () => {
    setEncryptionEnabled(true);
    kid = 'rotation-"雪"\\key';
    const messages: ChatMessage[] = [{ role: "user", content: [{ type: "text", text: 'hello <>&\u2028💡' }, { type: "image_url", image_url: { url: image(1024) } }] }];
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(keyCalls).toBe(1);
    expect(chatCalls).toBe(1);
    expect(upstreamCalls).toBe(1);
    expect(openedBody).toBe(requestJson(messages));
    expect(JSON.parse(sentBody).kid).toBe(kid);
    expect(cb.onError).not.toHaveBeenCalled();
  });

  it.each([0, 1])("checks the actual sealed envelope at the cap plus %i plaintext byte", async (extra) => {
    setEncryptionEnabled(true);
    // Independent codec arithmetic: 112 JSON/key bytes for a 16-character kid,
    // 24 nonce bytes and 16 authentication bytes, then base64 groups of four.
    const maxPlaintext = 3 * ((LIMIT - 112) / 4) - 40;
    const messages = textMessagesAtBytes(maxPlaintext + extra);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(keyCalls).toBe(1); // optimistic lower bound requires actual metadata
    expect(chatCalls).toBe(extra === 0 ? 1 : 0);
    if (extra) expectSizeError(cb);
    else {
      expect(encoder.encode(sentBody).byteLength).toBe(LIMIT);
      expect(openedBody).toBe(requestJson(messages));
    }
  });

  it.each([0, 1])("accounts for escaped Unicode key metadata at the cap plus %i plaintext byte", async (extra) => {
    setEncryptionEnabled(true);
    kid = 'rotation-"雪"\\key';
    const overhead = () => encoder.encode(JSON.stringify({
      kid, ephemeral_public_key: "a".repeat(44), ciphertext: "",
    })).byteLength;
    // Align metadata to a base64 group so the accepted case is exactly at cap.
    while (overhead() % 4 !== 0) kid += "a";
    const messages = textMessagesAtBytes(3 * ((LIMIT - overhead()) / 4) - 40 + extra);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb);
    expect(keyCalls).toBe(1);
    expect(chatCalls).toBe(extra === 0 ? 1 : 0);
    if (extra) expectSizeError(cb);
    else {
      expect(encoder.encode(sentBody).byteLength).toBe(LIMIT);
      expect(JSON.parse(sentBody).kid).toBe(kid);
      expect(openedBody).toBe(requestJson(messages));
    }
  });

  it("preserves a valid four-image request and the thinking override", async () => {
    const messages = toApiMessages([{ role: "user", content: "describe", images: [image(1), image(2), image(3), image(4)] }]);
    const cb = callbacks();
    await streamChat(messages, MODEL, cb, undefined, { enableThinking: false });
    expect(chatCalls).toBe(1);
    expect(JSON.parse(sentBody)).toEqual({ model: MODEL, messages, stream: true, enable_thinking: false });
    expect(cb.onError).not.toHaveBeenCalled();
  });

  it("retains the existing encryption setup error for key-service failures", async () => {
    setEncryptionEnabled(true);
    vi.mocked(fetch).mockResolvedValueOnce(new Response("", { status: 503 }));
    const cb = callbacks();
    await streamChat([{ role: "user", content: "hello" }], MODEL, cb);
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(chatCalls).toBe(0);
    expect(cb.onError).toHaveBeenCalledTimes(1);
    expect(vi.mocked(cb.onError).mock.calls[0][0]).toMatch(/Encryption setup failed/);
  });
});
