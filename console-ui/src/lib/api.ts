// All requests go through Next.js API routes (/api/*) to avoid CORS.
// The coordinator URL and API key are passed as custom headers so the
// server-side route can forward them to the upstream coordinator.

import {
  SEALED_CONTENT_TYPE,
  clearCoordinatorKeyCache,
  getCoordinatorKey,
  isEncryptionEnabled,
  sealRequest,
  unsealResponse,
  unsealSseEvent,
} from "./encryption";

const DEFAULT_COORDINATOR =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

const getConfig = () => {
  if (typeof window === "undefined") return { apiKey: "", baseUrl: DEFAULT_COORDINATOR };
  return {
    apiKey: localStorage.getItem("darkbloom_api_key") || "",
    baseUrl:
      localStorage.getItem("darkbloom_coordinator_url") || DEFAULT_COORDINATOR,
  };
};

/** Headers that tell our API proxy where to forward and how to auth. */
function proxyHeaders(extra?: Record<string, string>): Record<string, string> {
  const { apiKey, baseUrl } = getConfig();
  return {
    "Content-Type": "application/json",
    "x-coordinator-url": baseUrl,
    ...(apiKey ? { "x-api-key": apiKey } : {}),
    ...extra,
  };
}

export interface Model {
  id: string;
  object: string;
  owned_by?: string;
  size_bytes?: number;
  model_type?: string;
  quantization?: string;
  provider_count?: number;
  attested?: boolean;
  trust_level?: string;
  display_name?: string;
}

export interface BalanceResponse {
  balance_micro_usd: number;
  balance_usd: number;
}

export interface UsageEntry {
  request_id: string;
  model: string;
  prompt_tokens: number;
  completion_tokens: number;
  cost_micro_usd: number;
  timestamp: string;
}

export interface ChatMessage {
  role: "user" | "assistant" | "system";
  content: string;
}

export interface TrustMetadata {
  attested: boolean;
  trustLevel: "none" | "hardware";
  secureEnclave: boolean;
  mdaVerified: boolean;
  providerChip: string;
  providerSerial: string;
  providerModel: string;
  // Attestation receipt fields (per-request SE signature)
  responseHash?: string;
  seSignature?: string;
  sePublicKey?: string;
  deviceSerial?: string;
}

export interface StreamMetrics {
  tps: number;
  ttft: number;
  tokenCount: number;
}

export interface StreamCallbacks {
  onToken: (token: string) => void;
  onThinking: (token: string) => void;
  onMetrics: (metrics: StreamMetrics) => void;
  onDone: (trustMeta: TrustMetadata, metrics: StreamMetrics) => void;
  onError: (error: string) => void;
}

export interface TranscriptionResult {
  text: string;
  language?: string;
  duration?: number;
  segments?: { start: number; end: number; text: string }[];
}

export async function transcribeAudio(
  file: File | Blob,
  model: string,
  language?: string
): Promise<TranscriptionResult> {
  const { apiKey, baseUrl } = getConfig();

  const form = new FormData();
  const filename = file instanceof File
    ? file.name
    : file.type?.includes("webm") ? "recording.webm" : "recording.wav";
  form.append("file", file, filename);
  form.append("model", model);
  if (language) form.append("language", language);

  const res = await fetch("/api/transcribe", {
    method: "POST",
    headers: {
      "x-coordinator-url": baseUrl,
      ...(apiKey ? { "x-api-key": apiKey } : {}),
    },
    body: form,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Transcription failed (${res.status}): ${text}`);
  }

  return res.json();
}

export async function fetchModels(): Promise<Model[]> {
  const res = await fetch("/api/models", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch models: ${res.status}`);
  const data = await res.json();
  const raw = data.data || data;
  // Flatten metadata into top-level fields for the UI
  return raw.map((m: Record<string, unknown>) => {
    const meta = (m.metadata || {}) as Record<string, unknown>;
    return {
      ...m,
      model_type: m.model_type || meta.model_type,
      quantization: m.quantization || meta.quantization,
      provider_count: m.provider_count ?? meta.provider_count,
      trust_level: m.trust_level || meta.trust_level,
      attested: m.attested ?? (meta.attested_providers as number) > 0,
      display_name: m.display_name || meta.display_name,
    };
  });
}

export interface PriceEntry {
  model: string;
  input_price: number;
  output_price: number;
  input_usd: string;
  output_usd: string;
}

export interface TranscriptionPriceEntry {
  model: string;
  price_per_minute: number;
  price_usd: string;
  unit: string;
}

export interface ImagePriceEntry {
  model: string;
  price_per_image: number;
  price_usd: string;
  unit: string;
}

export interface PricingResponse {
  prices: PriceEntry[];
  transcription_prices: TranscriptionPriceEntry[];
  image_prices: ImagePriceEntry[];
}

export async function fetchPricing(): Promise<PricingResponse> {
  const res = await fetch("/api/pricing", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch pricing: ${res.status}`);
  return res.json();
}

export async function fetchBalance(): Promise<BalanceResponse> {
  const res = await fetch("/api/payments/balance", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch balance: ${res.status}`);
  return res.json();
}

export async function fetchUsage(): Promise<UsageEntry[]> {
  const res = await fetch("/api/payments/usage", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch usage: ${res.status}`);
  const data = await res.json();
  return data.usage || data;
}

export interface WalletInfo {
  credit_balance_micro_usd: number;
  wallet_address?: string;
  wallet_usdc_balance?: number;
  wallet_usdc_usd?: string;
  coordinator_address?: string;
}

export async function fetchWalletInfo(): Promise<WalletInfo> {
  const res = await fetch("/api/payments/wallet", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch wallet info: ${res.status}`);
  return res.json();
}

export async function deposit(amountUsd: number): Promise<void> {
  const res = await fetch("/api/payments/deposit", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data?.error?.message || data?.error || `Deposit failed (${res.status})`);
  }
}

export async function withdraw(amountUsd: number, walletAddress: string): Promise<void> {
  const res = await fetch("/api/payments/withdraw", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd, wallet_address: walletAddress }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data?.error?.message || data?.error || `Withdrawal failed (${res.status})`);
  }
}

export async function submitDepositTx(txSignature: string, referralCode?: string): Promise<void> {
  const res = await fetch("/api/payments/deposit", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ tx_signature: txSignature, referral_code: referralCode }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data?.error?.message || data?.error || `Deposit verification failed (${res.status})`);
  }
}

export interface ImageGenerationRequest {
  model: string;
  prompt: string;
  negative_prompt?: string;
  n?: number;
  size?: string;
  steps?: number;
  seed?: number;
}

export interface GeneratedImage {
  b64_json: string;
}

export interface ImageGenerationResponse {
  created: number;
  data: GeneratedImage[];
}

export async function generateImage(
  params: ImageGenerationRequest
): Promise<ImageGenerationResponse> {
  const res = await fetch("/api/images", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify(params),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Image generation failed (${res.status}): ${text}`);
  }
  return res.json();
}

export interface InviteRedeemResponse {
  credited_usd: string;
  balance_usd: string;
}

export async function redeemInviteCode(code: string): Promise<InviteRedeemResponse> {
  const res = await fetch("/api/invite/redeem", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ code }),
  });
  const data = await res.json();
  if (!res.ok) {
    const msg = data?.error?.message || data?.message || `Redemption failed (${res.status})`;
    throw new Error(msg);
  }
  return data;
}

export async function healthCheck(): Promise<{ status: string; providers: number }> {
  const res = await fetch("/api/health", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Health check failed: ${res.status}`);
  return res.json();
}

export async function streamChat(
  messages: ChatMessage[],
  model: string,
  callbacks: StreamCallbacks,
  signal?: AbortSignal
): Promise<void> {
  // Optional sender→coordinator encryption. Defaults off so plaintext SDK
  // and curl flows keep working unchanged. When enabled we NaCl-Box-seal the
  // outgoing body to the coordinator's published X25519 pubkey, then decrypt
  // each SSE event on the way back.
  const requestBody = { model, messages, stream: true };
  let sealCtx: { ephemPriv: Uint8Array; coordPub: Uint8Array } | null = null;
  let fetchHeaders = proxyHeaders();
  let fetchBody: string;

  if (isEncryptionEnabled()) {
    try {
      const coordKey = await getCoordinatorKey();
      const sealed = sealRequest(requestBody, coordKey);
      fetchBody = sealed.envelopeJson;
      fetchHeaders = proxyHeaders({ "Content-Type": SEALED_CONTENT_TYPE });
      sealCtx = {
        ephemPriv: sealed.ephemeralPrivateKey,
        coordPub: coordKey.publicKey,
      };
    } catch (err) {
      // Hard-fail per "don't silently fall back" rule. The user opted in to
      // encryption, so plaintext-fallback would defeat the purpose.
      callbacks.onError(
        `Encryption setup failed: ${err instanceof Error ? err.message : String(err)} — disable "Encrypt to coordinator" in Settings to continue in plaintext.`,
      );
      return;
    }
  } else {
    fetchBody = JSON.stringify(requestBody);
  }

  const res = await fetch("/api/chat", {
    method: "POST",
    headers: fetchHeaders,
    body: fetchBody,
    signal,
  });

  // If the coordinator advertised a kid mismatch (we cached a stale rotation),
  // clear our cache so the next attempt re-fetches the fresh pubkey.
  if (sealCtx && res.status === 400) {
    const text = await res.clone().text();
    if (text.includes("kid_mismatch")) {
      clearCoordinatorKeyCache();
    }
  }

  if (!res.ok) {
    // If 401, key is stale — clear it so useAuth re-provisions on next render
    if (res.status === 401) {
      localStorage.removeItem("darkbloom_api_key");
      // Dispatch event so useAuth can re-provision with Privy token
      window.dispatchEvent(new Event("darkbloom-key-expired"));
      callbacks.onError("Session expired — please try again");
      return;
    }
    let text = await res.text();
    // When the request was sealed, the coordinator seals 4xx/5xx bodies too
    // (so middleboxes still can't see what went wrong). Decrypt the envelope
    // before trying to parse a user-facing message.
    const errCt = res.headers.get("content-type") || "";
    const errSealed =
      sealCtx && (res.headers.get("x-eigen-sealed") === "true" ||
        errCt.toLowerCase().startsWith(SEALED_CONTENT_TYPE));
    if (errSealed && sealCtx) {
      try {
        const pt = unsealResponse(text, sealCtx.ephemPriv, sealCtx.coordPub);
        text = new TextDecoder().decode(pt);
      } catch (err) {
        callbacks.onError(
          `Could not decrypt sealed error response: ${err instanceof Error ? err.message : String(err)}`,
        );
        return;
      }
    }
    // Parse error for user-friendly messages
    try {
      const errData = JSON.parse(text);
      const msg = errData?.error?.message || text;
      if (res.status === 503 && msg.includes("queue timeout")) {
        callbacks.onError("All providers are busy — please try again in a moment");
      } else if (res.status === 402) {
        callbacks.onError("Insufficient credits — buy credits in Billing to continue");
      } else {
        callbacks.onError(`Request failed (${res.status}): ${msg}`);
      }
    } catch {
      callbacks.onError(`Request failed (${res.status}): ${text}`);
    }
    return;
  }

  const trustMeta: TrustMetadata = {
    attested: res.headers.get("x-provider-attested") === "true",
    trustLevel: (res.headers.get("x-provider-trust-level") as TrustMetadata["trustLevel"]) || "none",
    secureEnclave: res.headers.get("x-provider-secure-enclave") === "true",
    mdaVerified: res.headers.get("x-provider-mda-verified") === "true",
    providerChip: res.headers.get("x-provider-chip") || "",
    providerSerial: res.headers.get("x-provider-serial") || "",
    providerModel: res.headers.get("x-provider-model") || "",
    // Attestation receipt fields (populated from headers + SSE events)
    sePublicKey: res.headers.get("x-attestation-se-public-key") || undefined,
    deviceSerial: res.headers.get("x-attestation-device-serial") || undefined,
  };

  const reader = res.body?.getReader();
  if (!reader) {
    callbacks.onError("No response body");
    return;
  }

  const decoder = new TextDecoder();
  let buffer = "";

  // Metrics tracking
  const requestStart = performance.now();
  let firstTokenTime = 0;
  let lastTokenTime = 0;
  let tokenCount = 0;

  // Think-block state machine
  // Supports multiple formats:
  //   Qwen/DeepSeek: "<think>...</think>" or "Thinking Process:\n...</think>"
  //   Gemma 4:       "<|channel>thought\n...<channel|>"
  let inThinkBlock = false;
  let thinkCloseTag = "</think>"; // updated per-format when block detected
  let contentAccum = "";
  let thinkDetectionDone = false;
  let thinkCloseBuffer = ""; // buffers tokens to detect close tag split across chunks

  function emitMetrics() {
    if (!firstTokenTime) return;
    const elapsed = ((lastTokenTime || performance.now()) - firstTokenTime) / 1000;
    const tps = elapsed > 0 ? tokenCount / elapsed : 0;
    const ttft = firstTokenTime - requestStart;
    callbacks.onMetrics({ tps, ttft, tokenCount });
  }

  /** Flush any buffered content that the think-detector accumulated. */
  function flushContentAccum() {
    if (!thinkDetectionDone && contentAccum) {
      thinkDetectionDone = true;
      callbacks.onToken(contentAccum);
      contentAccum = "";
    }
    // Flush any remaining think close-tag buffer (truncated thinking)
    if (inThinkBlock && thinkCloseBuffer) {
      callbacks.onThinking(thinkCloseBuffer);
      thinkCloseBuffer = "";
    }
  }

  function handleContentToken(text: string) {
    // On first content tokens, detect if this is a think block
    if (!thinkDetectionDone) {
      contentAccum += text;
      // Wait for enough chars to decide (need ~18 for "Thinking Process:" / "<|channel>thought")
      if (contentAccum.length < 20 && !contentAccum.includes("\n\n") && !contentAccum.includes("<channel|>")) return;

      thinkDetectionDone = true;
      const trimmed = contentAccum.trimStart();

      // Qwen/DeepSeek: <think>...
      if (trimmed.startsWith("<think>")) {
        inThinkBlock = true;
        thinkCloseTag = "</think>";
        const afterTag = contentAccum.replace(/^\s*<think>\s*/, "");
        if (afterTag) callbacks.onThinking(afterTag);
        return;
      }
      // Qwen legacy: Thinking Process:...
      if (trimmed.startsWith("Thinking Process:") || trimmed.startsWith("Thinking Process\n")) {
        inThinkBlock = true;
        thinkCloseTag = "</think>";
        const afterTag = trimmed.replace(/^Thinking Process:?\s*/, "");
        if (afterTag) callbacks.onThinking(afterTag);
        return;
      }
      // Gemma 4: <|channel>thought\n...<channel|>
      if (trimmed.startsWith("<|channel>thought")) {
        inThinkBlock = true;
        thinkCloseTag = "<channel|>";
        const afterTag = trimmed.replace(/^<\|channel>thought\s*/, "");
        if (afterTag) callbacks.onThinking(afterTag);
        return;
      }

      // Not a think block — flush accumulated content as normal tokens
      callbacks.onToken(contentAccum);
      return;
    }

    if (inThinkBlock) {
      // Buffer to handle close tag split across token boundaries
      thinkCloseBuffer += text;
      const closeIdx = thinkCloseBuffer.indexOf(thinkCloseTag);
      if (closeIdx !== -1) {
        const before = thinkCloseBuffer.slice(0, closeIdx);
        if (before) callbacks.onThinking(before);
        const after = thinkCloseBuffer.slice(closeIdx + thinkCloseTag.length);
        inThinkBlock = false;
        thinkCloseBuffer = "";
        if (after.replace(/^\n+/, "")) callbacks.onToken(after.replace(/^\n+/, ""));
        return;
      }
      // Flush confirmed non-close content (keep last N chars as potential partial close tag)
      const tagLen = thinkCloseTag.length;
      if (thinkCloseBuffer.length > tagLen) {
        const safe = thinkCloseBuffer.slice(0, -tagLen);
        callbacks.onThinking(safe);
        thinkCloseBuffer = thinkCloseBuffer.slice(-tagLen);
      }
      return;
    }

    // Safety net: strip any residual thinking tags that the state machine missed
    const cleaned = text
      .replace(/<\|channel>thought[\s\S]*?<channel\|>/g, "")
      .replace(/<think>[\s\S]*?<\/think>/g, "");
    if (cleaned) callbacks.onToken(cleaned);
  }

  // When the response is sealed, the wire format is
  // `data: <b64(nonce||sealed)>\n\n` per upstream event. We unseal each event
  // back to its original `data: {...}` form before feeding it to the parser.
  const responseSealed = sealCtx !== null && res.headers.get("x-eigen-sealed") === "true";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || !trimmed.startsWith("data: ")) continue;

      let payload = trimmed.slice(6);
      if (responseSealed && sealCtx) {
        try {
          const inner = unsealSseEvent(payload, sealCtx.ephemPriv, sealCtx.coordPub);
          // Inner is the upstream event minus the trailing \n\n — typically
          // `data: {...}` or `data: [DONE]`. Strip the inner data: prefix so
          // the existing parser sees the same shape it always has.
          const innerTrimmed = inner.trim();
          if (innerTrimmed.startsWith("data: ")) {
            payload = innerTrimmed.slice(6);
          } else {
            payload = innerTrimmed;
          }
        } catch (err) {
          callbacks.onError(
            `Sealed stream decryption failed: ${err instanceof Error ? err.message : String(err)}`,
          );
          return;
        }
      }
      if (payload === "[DONE]") {
        flushContentAccum();
        emitMetrics();
        const elapsed = firstTokenTime && lastTokenTime ? (lastTokenTime - firstTokenTime) / 1000 : 0;
        callbacks.onDone(trustMeta, {
          tps: elapsed > 0 ? tokenCount / elapsed : 0,
          ttft: firstTokenTime ? firstTokenTime - requestStart : 0,
          tokenCount,
        });
        return;
      }

      // Check for attestation receipt event (sent just before [DONE])
      try {
        const receiptCheck = JSON.parse(payload);
        if (receiptCheck.se_signature) {
          trustMeta.seSignature = receiptCheck.se_signature;
          trustMeta.responseHash = receiptCheck.response_hash;
          continue;
        }
      } catch {
        // Not a receipt — normal chunk processing continues below
      }

      try {
        const chunk = JSON.parse(payload);
        const delta = chunk.choices?.[0]?.delta;
        const content = delta?.content;
        const reasoning = delta?.reasoning_content || delta?.reasoning;

        if (reasoning || content) {
          tokenCount++;
          const now = performance.now();
          if (!firstTokenTime) firstTokenTime = now;
          lastTokenTime = now;

          if (reasoning) {
            // If we have buffered content that was waiting for think detection,
            // and reasoning just started, the buffered content is the opening
            // think tag (e.g. "<|channel>thought"). Discard it — it's not real content.
            if (!thinkDetectionDone && contentAccum) {
              thinkDetectionDone = true;
              inThinkBlock = false; // server handles the extraction
              contentAccum = "";
            }
            callbacks.onThinking(reasoning);
          }
          if (content) handleContentToken(content);

          // Emit metrics every 5 tokens to avoid excessive updates
          if (tokenCount % 5 === 0) emitMetrics();
        }
      } catch {
        // skip malformed chunks
      }
    }
  }

  // Stream ended without [DONE]
  flushContentAccum();
  emitMetrics();
  const elapsed = firstTokenTime && lastTokenTime ? (lastTokenTime - firstTokenTime) / 1000 : 0;
  callbacks.onDone(trustMeta, {
    tps: elapsed > 0 ? tokenCount / elapsed : 0,
    ttft: firstTokenTime ? firstTokenTime - requestStart : 0,
    tokenCount,
  });
}
