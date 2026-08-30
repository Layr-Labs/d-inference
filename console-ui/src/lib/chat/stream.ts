// Chat streaming orchestration. Decomposed out of the old 354-line
// streamChat (ESLint cognitive-complexity 119): the think-block FSM now lives
// in think-parser.ts, the SSE line buffering in sse.ts, and the
// transport/error/metrics plumbing is factored into the small helpers below
// (proposal F1).

import { STORAGE_KEYS } from "../constants";
import { proxyHeaders } from "../http/proxy-client";
import {
  sealPrivateV2Request,
  type PrivateV2PlainChunk,
  type PrivateV2WireChunk,
  type SealedPrivateV2Request,
} from "../private-v2";
import type {
  ChatMessage,
  StreamCallbacks,
  StreamMetrics,
  TrustMetadata,
} from "../api/types";
import { ThinkStreamParser } from "./think-parser";
import { readSsePayloads } from "./sse";

function verifiedTrustMetadata(
  destination: SealedPrivateV2Request["destination"],
  model: string,
  routeMode: SealedPrivateV2Request["routeMode"],
): TrustMetadata {
  return {
    attested: true,
    trustLevel: "hardware",
    secureEnclave: true,
    mdaVerified: true,
    providerChip: "",
    providerModel: model,
    privacyTier: "private-v2-process-bound",
    routeMode,
    sePublicKey: destination.sePublicKey,
  };
}
/** Track TTFT / TPS / token count across the stream. */
class StreamMetricsTracker {
  firstTokenTime = 0;
  lastTokenTime = 0;
  tokenCount = 0;
  constructor(private readonly requestStart: number) {}

  record(): void {
    const now = performance.now();
    this.tokenCount++;
    if (!this.firstTokenTime) this.firstTokenTime = now;
    this.lastTokenTime = now;
  }

  snapshot(): StreamMetrics {
    const elapsed = this.firstTokenTime && this.lastTokenTime
      ? (this.lastTokenTime - this.firstTokenTime) / 1000
      : 0;
    return {
      tps: elapsed > 0 ? this.tokenCount / elapsed : 0,
      ttft: this.firstTokenTime ? this.firstTokenTime - this.requestStart : 0,
      tokenCount: this.tokenCount,
    };
  }

  emit(onMetrics: (m: StreamMetrics) => void): void {
    if (!this.firstTokenTime) return;
    const elapsed = ((this.lastTokenTime || performance.now()) - this.firstTokenTime) / 1000;
    onMetrics({
      tps: elapsed > 0 ? this.tokenCount / elapsed : 0,
      ttft: this.firstTokenTime - this.requestStart,
      tokenCount: this.tokenCount,
    });
  }
}

function privateV2Error(status: number, body: string): string {
  try {
    const parsed = JSON.parse(body) as { error?: { message?: string; code?: string } | string };
    if (typeof parsed.error === "string") return `Private v2 failed (${status}): ${parsed.error}`;
    if (parsed.error?.message) {
      return `Private v2 failed (${status}): ${parsed.error.message}`;
    }
  } catch {
    // Preserve the opaque coordinator error below.
  }
  return `Private v2 failed (${status}): ${body || "empty response"}`;
}

async function readBoundedErrorText(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return "";
  const limit = 64 * 1024;
  const bytes = new Uint8Array(limit);
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value.length > limit - length) {
      await reader.cancel("private-v2 error response byte limit exceeded");
      return "error response exceeded 64 KiB limit";
    }
    bytes.set(value, length);
    length += value.length;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, length));
  } catch {
    return "error response was not valid UTF-8";
  }
}

function chunkPayload(value: PrivateV2PlainChunk): Record<string, unknown> | null {
  if (!value.payload || typeof value.payload !== "object" || Array.isArray(value.payload)) return null;
  return value.payload as Record<string, unknown>;
}

function expireApiKey(): void {
  localStorage.removeItem(STORAGE_KEYS.apiKey);
  window.dispatchEvent(new Event("darkbloom-key-expired"));
}

function requiresVision(messages: ChatMessage[]): boolean {
  return messages.some(
    (message) =>
      Array.isArray(message.content) &&
      message.content.some((part) => part.type === "image_url"),
  );
}

export async function streamChat(
  messages: ChatMessage[],
  model: string,
  callbacks: StreamCallbacks,
  signal?: AbortSignal,
  opts?: { selfRoute?: boolean },
): Promise<void> {
  const endpoint = "chat.completions" as const;
  const requestedMaxOutputTokens = 4096;
  const vision = requiresVision(messages);
  const routeMode = opts?.selfRoute ? "self_route_only" as const : "public" as const;
  const requestBody = { model, messages, stream: true, max_tokens: requestedMaxOutputTokens };
  const routeHeader = opts?.selfRoute ? { "X-Darkbloom-Route": "self" } : {};
  const headers = proxyHeaders(routeHeader);
  const tracker = new StreamMetricsTracker(performance.now());

  const preflightResponse = await fetch("/api/private/preflight", {
    method: "POST",
    headers,
    body: JSON.stringify({
      model,
      endpoint,
      stream: true,
      requested_max_output_tokens: requestedMaxOutputTokens,
      requires_vision: vision,
    }),
    signal,
  });
  if (!preflightResponse.ok) {
    if (preflightResponse.status === 401) expireApiKey();
    callbacks.onError(privateV2Error(
      preflightResponse.status,
      await readBoundedErrorText(preflightResponse),
    ));
    return;
  }

  let preflight: unknown;
  try {
    preflight = await preflightResponse.json();
  } catch {
    callbacks.onError("Private v2 preflight returned invalid JSON");
    return;
  }

  let sealed: SealedPrivateV2Request;
  try {
    sealed = await sealPrivateV2Request(
      preflight,
      {
        endpoint,
        stream: true,
        requestedMaxOutputTokens,
        requiresVision: vision,
        routeMode,
      },
      requestBody,
    );
  } catch (error) {
    callbacks.onError(
      `Private v2 cryptographic validation failed: ${error instanceof Error ? error.message : String(error)}`,
    );
    return;
  }

  try {
    const response = await fetch("/api/private/requests", {
      method: "POST",
      headers,
      body: JSON.stringify(sealed.envelope),
      signal,
    });
    if (!response.ok) {
      if (response.status === 401) expireApiKey();
      callbacks.onError(privateV2Error(
        response.status,
        await readBoundedErrorText(response),
      ));
      return;
    }
    if (response.headers.get("x-darkbloom-privacy-tier") !== "private-v2-process-bound") {
      callbacks.onError("Private v2 response was missing its process-bound privacy tier");
      return;
    }

    const trustMeta = verifiedTrustMetadata(
      sealed.destination,
      sealed.model,
      sealed.routeMode,
    );
    const reader = response.body?.getReader();
    if (!reader) {
      callbacks.onError("Private v2 response had no body");
      return;
    }
    const think = new ThinkStreamParser(callbacks.onThinking, callbacks.onToken);

    const finish = () => {
      think.flush();
      tracker.emit(callbacks.onMetrics);
      callbacks.onDone(trustMeta, tracker.snapshot());
    };

    for await (const rawPayload of readSsePayloads(reader)) {
      let wire: PrivateV2WireChunk;
      try {
        wire = JSON.parse(rawPayload) as PrivateV2WireChunk;
      } catch {
        callbacks.onError("Private v2 response contained malformed encrypted framing");
        return;
      }

      let plain: PrivateV2PlainChunk;
      try {
        plain = await sealed.session.decryptChunk(wire);
      } catch (error) {
        callbacks.onError(
          `Private v2 response rejected: ${error instanceof Error ? error.message : String(error)}`,
        );
        return;
      }

      const payload = chunkPayload(plain);
      if (!payload && !plain.terminal) {
        callbacks.onError("Private v2 response contained an invalid endpoint payload");
        return;
      }
      if (payload?.error) {
        const error = payload.error;
        const message = typeof error === "object" && error
          ? String((error as Record<string, unknown>).message || "provider error")
          : String(error);
        callbacks.onError(`Private v2 provider error: ${message}`);
        return;
      }

      if (payload?.se_signature) {
        trustMeta.seSignature = String(payload.se_signature);
        trustMeta.responseHash = String(payload.response_hash || "");
      } else if (payload) {
        const choices = payload.choices;
        const first = Array.isArray(choices) ? choices[0] : undefined;
        const delta = first && typeof first === "object"
          ? (first as Record<string, unknown>).delta
          : undefined;
        const deltaRecord = delta && typeof delta === "object"
          ? delta as Record<string, unknown>
          : undefined;
        const content = typeof deltaRecord?.content === "string" ? deltaRecord.content : "";
        const reasoningValue = deltaRecord?.reasoning_content ?? deltaRecord?.reasoning;
        const reasoning = typeof reasoningValue === "string" ? reasoningValue : "";
        if (reasoning || content) {
          tracker.record();
          if (reasoning) {
            think.onReasoningStart();
            callbacks.onThinking(reasoning);
          }
          if (content) think.handleContent(content);
          if (tracker.tokenCount % 5 === 0) tracker.emit(callbacks.onMetrics);
        }
      }

      if (plain.terminal) {
        finish();
        return;
      }
    }

    callbacks.onError("Private v2 stream ended before an authenticated terminal chunk");
  } finally {
    sealed.session.dispose();
  }
}
