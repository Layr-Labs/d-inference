// Chat streaming orchestration. Decomposed out of the old 354-line
// streamChat (ESLint cognitive-complexity 119): the think-block FSM now lives
// in think-parser.ts, the SSE line buffering in sse.ts, and the
// transport/error/metrics plumbing is factored into the small helpers below
// (proposal F1).

import {
  SEALED_CONTENT_TYPE,
  clearCoordinatorKeyCache,
  getCoordinatorKey,
  isEncryptionEnabled,
  sealRequest,
  unsealResponse,
  unsealSseEvent,
} from "../encryption";
import { STORAGE_KEYS } from "../constants";
import { proxyHeaders } from "../http/proxy-client";
import type {
  ChatMessage,
  StreamCallbacks,
  StreamMetrics,
  TrustMetadata,
} from "../api/types";
import { ThinkStreamParser } from "./think-parser";
import { readSsePayloads } from "./sse";

type SealContext = { ephemPriv: Uint8Array; coordPub: Uint8Array };

/** Map an upstream error (status + message + error code) to user-facing copy. */
function chatErrorMessage(status: number, msg: string, code?: string): string {
  if (code === "no_linked_machine") {
    return "No machine linked to your account — run `darkbloom login` on your Mac, then try again.";
  }
  if (code === "machine_offline") {
    return "Your machine is offline — start your Darkbloom node and try again. (Free-only self-route won't fall back to the paid network.)";
  }
  if (code === "model_not_loaded") {
    return "This model isn't loaded on your machine — load it on your node, then try again.";
  }
  if (code === "machine_busy") {
    return "Your machine is busy — try again in a moment.";
  }
  if (status === 503 && msg.includes("queue timeout")) {
    return "All providers are busy — please try again in a moment";
  }
  if (status === 402) {
    return "Insufficient credits — buy credits in Billing to continue";
  }
  return `Request failed (${status}): ${msg}`;
}

/** Extract the provider trust metadata advertised on the response headers. */
function extractTrustMeta(res: Response): TrustMetadata {
  return {
    attested: res.headers.get("x-provider-attested") === "true",
    trustLevel: (res.headers.get("x-provider-trust-level") as TrustMetadata["trustLevel"]) || "none",
    secureEnclave: res.headers.get("x-provider-secure-enclave") === "true",
    mdaVerified: res.headers.get("x-provider-mda-verified") === "true",
    providerChip: res.headers.get("x-provider-chip") || "",
    providerSerial: res.headers.get("x-provider-serial") || "",
    providerModel: res.headers.get("x-provider-model") || "",
    sePublicKey: res.headers.get("x-attestation-se-public-key") || undefined,
    deviceSerial: res.headers.get("x-attestation-device-serial") || undefined,
  };
}

/** Decode an error body (decrypting first when the response was sealed). */
async function decodeErrorBody(res: Response, sealCtx: SealContext | null): Promise<string> {
  let text = await res.text();
  const errCt = res.headers.get("content-type") || "";
  const errSealed =
    sealCtx && (res.headers.get("x-eigen-sealed") === "true" ||
      errCt.toLowerCase().startsWith(SEALED_CONTENT_TYPE));
  if (errSealed && sealCtx) {
    const pt = unsealResponse(text, sealCtx.ephemPriv, sealCtx.coordPub);
    text = new TextDecoder().decode(pt);
  }
  return text;
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

/** Build the (optionally sealed) request body + headers for /api/chat. */
async function prepareBody(
  requestBody: unknown,
  selfRouteHeader: Record<string, string>,
): Promise<{ headers: Record<string, string>; body: string; sealCtx: SealContext | null }> {
  if (!isEncryptionEnabled()) {
    return { headers: proxyHeaders(selfRouteHeader), body: JSON.stringify(requestBody), sealCtx: null };
  }
  const coordKey = await getCoordinatorKey();
  const sealed = sealRequest(requestBody, coordKey);
  return {
    headers: proxyHeaders({ "Content-Type": SEALED_CONTENT_TYPE, ...selfRouteHeader }),
    body: sealed.envelopeJson,
    sealCtx: { ephemPriv: sealed.ephemeralPrivateKey, coordPub: coordKey.publicKey },
  };
}

export async function streamChat(
  messages: ChatMessage[],
  model: string,
  callbacks: StreamCallbacks,
  signal?: AbortSignal,
  opts?: { selfRoute?: boolean },
): Promise<void> {
  const requestBody = { model, messages, stream: true };
  // "Use my machine": prioritize the caller's own provider (free when it serves)
  // but fall back to the paid fleet. Carried as a header so it never enters the
  // (optionally sealed) body.
  const selfRouteHeader: Record<string, string> = opts?.selfRoute
    ? { "X-Darkbloom-Route": "prefer" }
    : {};

  let headers: Record<string, string>;
  let body: string;
  let sealCtx: SealContext | null;
  try {
    ({ headers, body, sealCtx } = await prepareBody(requestBody, selfRouteHeader));
  } catch (err) {
    callbacks.onError(
      `Encryption setup failed: ${err instanceof Error ? err.message : String(err)} — disable "Encrypt to coordinator" in Settings to continue in plaintext.`,
    );
    return;
  }

  const tracker = new StreamMetricsTracker(performance.now());
  const res = await fetch("/api/chat", { method: "POST", headers, body, signal });

  // Stale cached rotation — drop the cache so the next attempt re-fetches.
  if (sealCtx && res.status === 400) {
    const text = await res.clone().text();
    if (text.includes("kid_mismatch")) clearCoordinatorKeyCache();
  }

  if (!res.ok) {
    if (res.status === 401) {
      localStorage.removeItem(STORAGE_KEYS.apiKey);
      window.dispatchEvent(new Event("darkbloom-key-expired"));
      callbacks.onError("Session expired — please try again");
      return;
    }
    let text: string;
    try {
      text = await decodeErrorBody(res, sealCtx);
    } catch (err) {
      callbacks.onError(
        `Could not decrypt sealed error response: ${err instanceof Error ? err.message : String(err)}`,
      );
      return;
    }
    try {
      const errData = JSON.parse(text);
      callbacks.onError(
        chatErrorMessage(res.status, errData?.error?.message || text, errData?.error?.code),
      );
    } catch {
      callbacks.onError(`Request failed (${res.status}): ${text}`);
    }
    return;
  }

  const trustMeta = extractTrustMeta(res);
  const reader = res.body?.getReader();
  if (!reader) {
    callbacks.onError("No response body");
    return;
  }

  const think = new ThinkStreamParser(callbacks.onThinking, callbacks.onToken);
  const responseSealed = sealCtx !== null && res.headers.get("x-eigen-sealed") === "true";

  const finish = () => {
    think.flush();
    tracker.emit(callbacks.onMetrics);
    callbacks.onDone(trustMeta, tracker.snapshot());
  };

  for await (const rawPayload of readSsePayloads(reader)) {
    let payload = rawPayload;
    if (responseSealed && sealCtx) {
      try {
        const inner = unsealSseEvent(payload, sealCtx.ephemPriv, sealCtx.coordPub).trim();
        payload = inner.startsWith("data: ") ? inner.slice(6) : inner;
      } catch (err) {
        callbacks.onError(
          `Sealed stream decryption failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        return;
      }
    }

    if (payload === "[DONE]") {
      finish();
      return;
    }

    // Attestation receipt event (sent just before [DONE]).
    try {
      const receipt = JSON.parse(payload);
      if (receipt.se_signature) {
        trustMeta.seSignature = receipt.se_signature;
        trustMeta.responseHash = receipt.response_hash;
        continue;
      }
    } catch {
      // Not a receipt — fall through to normal chunk handling.
    }

    try {
      const chunk = JSON.parse(payload);
      const delta = chunk.choices?.[0]?.delta;
      const content = delta?.content;
      const reasoning = delta?.reasoning_content || delta?.reasoning;
      if (reasoning || content) {
        tracker.record();
        if (reasoning) {
          think.onReasoningStart();
          callbacks.onThinking(reasoning);
        }
        if (content) think.handleContent(content);
        if (tracker.tokenCount % 5 === 0) tracker.emit(callbacks.onMetrics);
      }
    } catch {
      // skip malformed chunks
    }
  }

  // Stream ended without an explicit [DONE].
  finish();
}
