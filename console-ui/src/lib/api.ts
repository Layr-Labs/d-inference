// All requests go through Next.js API routes (/api/*) to avoid CORS.
// The coordinator URL and API key are passed as custom headers so the
// server-side route can forward them to the upstream coordinator.

const DEFAULT_COORDINATOR =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://inference-test.openinnovation.dev";

const getConfig = () => {
  if (typeof window === "undefined") return { apiKey: "", baseUrl: DEFAULT_COORDINATOR };
  return {
    apiKey: localStorage.getItem("eigeninference_api_key") || "",
    baseUrl:
      localStorage.getItem("eigeninference_coordinator_url") || DEFAULT_COORDINATOR,
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
  trustLevel: "none" | "self_signed" | "hardware";
  secureEnclave: boolean;
  mdaVerified: boolean;
  providerChip: string;
  providerSerial: string;
  providerModel: string;
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
  form.append("file", file, file instanceof File ? file.name : "recording.wav");
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
    throw new Error(data?.error?.message || data?.error || `Purchase failed (${res.status})`);
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
  const res = await fetch("/api/chat", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ model, messages, stream: true }),
    signal,
  });

  if (!res.ok) {
    // If 401, key is stale — auto-regenerate and tell user to retry
    if (res.status === 401) {
      localStorage.removeItem("eigeninference_api_key");
      try {
        const keyRes = await fetch("/api/auth/keys", {
          method: "POST",
          headers: proxyHeaders(),
        });
        if (keyRes.ok) {
          const { api_key } = await keyRes.json();
          localStorage.setItem("eigeninference_api_key", api_key);
        }
      } catch { /* ignore */ }
      callbacks.onError("Session expired — please resend your message");
      return;
    }
    const text = await res.text();
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
  let tokenCount = 0;

  // Qwen think-block state machine
  // Qwen outputs "Thinking Process:\n...\n</think>" or "<think>...</think>" in content
  let inThinkBlock = false;
  let contentAccum = "";
  let thinkDetectionDone = false;
  let thinkCloseBuffer = ""; // buffers tokens to detect </think> split across chunks

  function emitMetrics() {
    if (!firstTokenTime) return;
    const elapsed = (performance.now() - firstTokenTime) / 1000;
    const tps = elapsed > 0 ? tokenCount / elapsed : 0;
    const ttft = firstTokenTime - requestStart;
    callbacks.onMetrics({ tps, ttft, tokenCount });
  }

  function handleContentToken(text: string) {
    // On first content tokens, detect if this is a Qwen think block
    // Qwen formats: "<think>..." or "Thinking Process:\n..."
    if (!thinkDetectionDone) {
      contentAccum += text;
      // Wait for enough chars to decide (need ~18 for "Thinking Process:")
      if (contentAccum.length < 18 && !contentAccum.includes("\n\n")) return;

      thinkDetectionDone = true;
      const trimmed = contentAccum.trimStart();
      if (trimmed.startsWith("<think>")) {
        inThinkBlock = true;
        const afterTag = contentAccum.replace(/^\s*<think>\s*/, "");
        if (afterTag) callbacks.onThinking(afterTag);
        return;
      }
      if (trimmed.startsWith("Thinking Process:") || trimmed.startsWith("Thinking Process\n")) {
        inThinkBlock = true;
        // Strip the "Thinking Process:" prefix and send rest as thinking
        const afterTag = trimmed.replace(/^Thinking Process:?\s*/, "");
        if (afterTag) callbacks.onThinking(afterTag);
        return;
      }
      // Not a think block — flush accumulated content as normal tokens
      callbacks.onToken(contentAccum);
      return;
    }

    if (inThinkBlock) {
      // Buffer to handle </think> split across token boundaries
      thinkCloseBuffer += text;
      const closeIdx = thinkCloseBuffer.indexOf("</think>");
      if (closeIdx !== -1) {
        const before = thinkCloseBuffer.slice(0, closeIdx);
        if (before) callbacks.onThinking(before);
        const after = thinkCloseBuffer.slice(closeIdx + 8);
        inThinkBlock = false;
        thinkCloseBuffer = "";
        if (after.replace(/^\n+/, "")) callbacks.onToken(after.replace(/^\n+/, ""));
        return;
      }
      // Flush confirmed non-close content (keep last 7 chars as potential partial </think>)
      if (thinkCloseBuffer.length > 8) {
        const safe = thinkCloseBuffer.slice(0, -8);
        callbacks.onThinking(safe);
        thinkCloseBuffer = thinkCloseBuffer.slice(-8);
      }
      return;
    }

    callbacks.onToken(text);
  }

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() || "";

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || !trimmed.startsWith("data: ")) continue;

      const payload = trimmed.slice(6);
      if (payload === "[DONE]") {
        emitMetrics();
        const elapsed = firstTokenTime ? (performance.now() - firstTokenTime) / 1000 : 0;
        callbacks.onDone(trustMeta, {
          tps: elapsed > 0 ? tokenCount / elapsed : 0,
          ttft: firstTokenTime ? firstTokenTime - requestStart : 0,
          tokenCount,
        });
        return;
      }

      try {
        const chunk = JSON.parse(payload);
        const delta = chunk.choices?.[0]?.delta;
        const content = delta?.content;
        const reasoning = delta?.reasoning_content || delta?.reasoning;

        if (reasoning || content) {
          tokenCount++;
          if (!firstTokenTime) firstTokenTime = performance.now();

          if (reasoning) callbacks.onThinking(reasoning);
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
  emitMetrics();
  const elapsed = firstTokenTime ? (performance.now() - firstTokenTime) / 1000 : 0;
  callbacks.onDone(trustMeta, {
    tps: elapsed > 0 ? tokenCount / elapsed : 0,
    ttft: firstTokenTime ? firstTokenTime - requestStart : 0,
    tokenCount,
  });
}
