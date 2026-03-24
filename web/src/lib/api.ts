// All requests go through Next.js API routes (/api/*) to avoid CORS.
// The coordinator URL and API key are passed as custom headers so the
// server-side route can forward them to the upstream coordinator.

const DEFAULT_COORDINATOR =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "http://localhost:8080";

const getConfig = () => {
  if (typeof window === "undefined") return { apiKey: "", baseUrl: DEFAULT_COORDINATOR };
  return {
    apiKey: localStorage.getItem("dginf_api_key") || "",
    baseUrl:
      localStorage.getItem("dginf_coordinator_url") || DEFAULT_COORDINATOR,
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
}

export interface StreamCallbacks {
  onToken: (token: string) => void;
  onDone: (trustMeta: TrustMetadata) => void;
  onError: (error: string) => void;
}

export async function fetchModels(): Promise<Model[]> {
  const res = await fetch("/api/models", { headers: proxyHeaders() });
  if (!res.ok) throw new Error(`Failed to fetch models: ${res.status}`);
  const data = await res.json();
  return data.data || data;
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

export async function deposit(amountUsd: number): Promise<void> {
  const res = await fetch("/api/payments/deposit", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd }),
  });
  if (!res.ok) throw new Error(`Deposit failed: ${res.status}`);
}

export async function withdraw(
  amountUsd: number,
  walletAddress: string
): Promise<void> {
  const res = await fetch("/api/payments/withdraw", {
    method: "POST",
    headers: proxyHeaders(),
    body: JSON.stringify({ amount_usd: amountUsd, wallet_address: walletAddress }),
  });
  if (!res.ok) throw new Error(`Withdrawal failed: ${res.status}`);
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
      localStorage.removeItem("dginf_api_key");
      try {
        const keyRes = await fetch("/api/auth/keys", {
          method: "POST",
          headers: proxyHeaders(),
        });
        if (keyRes.ok) {
          const { api_key } = await keyRes.json();
          localStorage.setItem("dginf_api_key", api_key);
        }
      } catch { /* ignore */ }
      callbacks.onError("Session expired — please resend your message");
      return;
    }
    const text = await res.text();
    callbacks.onError(`Request failed (${res.status}): ${text}`);
    return;
  }

  const trustMeta: TrustMetadata = {
    attested: res.headers.get("x-provider-attested") === "true",
    trustLevel: (res.headers.get("x-provider-trust-level") as TrustMetadata["trustLevel"]) || "none",
    secureEnclave: res.headers.get("x-provider-secure-enclave") === "true",
  };

  const reader = res.body?.getReader();
  if (!reader) {
    callbacks.onError("No response body");
    return;
  }

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

      const payload = trimmed.slice(6);
      if (payload === "[DONE]") {
        callbacks.onDone(trustMeta);
        return;
      }

      try {
        const chunk = JSON.parse(payload);
        const content = chunk.choices?.[0]?.delta?.content;
        if (content) callbacks.onToken(content);
      } catch {
        // skip malformed chunks
      }
    }
  }

  callbacks.onDone(trustMeta);
}
