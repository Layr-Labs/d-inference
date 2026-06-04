// Local-first chat with coordinator fallback.
//
// Direct mode (`darkbloom start --local`) exposes an OpenAI-compatible server on
// the user's own Mac. When a client can reach it, talking to it directly is
// lower-latency, works offline, and keeps bytes on the local network. When it
// can't (the Mac is asleep, you're away, or local mode isn't running), this
// helper falls back to the coordinator with `X-Darkbloom-Route: self` — the
// relayed "use my machine, for free" path.
//
// Fallback fires ONLY on a connection-level failure (fetch rejects / network
// unreachable). A reachable-but-erroring local server returns its own error
// rather than silently rerouting — predictable, and both paths are free anyway.
//
// This module is fetch-based and dependency-free so it runs in the browser, in
// Node, and in tests. Discovering the local endpoint from `~/.darkbloom/local.json`
// is a Node-only `fs` read (see docs/direct-mode.md); callers pass the resolved
// endpoint in (or null).

export interface LocalEndpoint {
  /** e.g. "http://127.0.0.1:8000/v1" (from `darkbloom local`). */
  baseURL: string;
  /** Local bearer token; omitted when the server runs with --no-auth. */
  apiKey?: string;
}

export interface FallbackConfig {
  /** Resolved local endpoint, or null when none is known/configured. */
  local: LocalEndpoint | null;
  /** Coordinator chat URL — the `/api/chat` proxy or a coordinator `/v1/chat/completions`. */
  coordinatorURL: string;
  /** Bearer token for the coordinator (your Darkbloom API key). */
  coordinatorApiKey: string;
}

export type RouteVia = "local" | "coordinator";

export interface FallbackResult {
  response: Response;
  via: RouteVia;
}

/** Build the request to the local server. */
export function buildLocalRequest(
  local: LocalEndpoint,
  body: unknown
): { url: string; init: RequestInit } {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (local.apiKey) headers["Authorization"] = `Bearer ${local.apiKey}`;
  return {
    url: `${local.baseURL.replace(/\/$/, "")}/chat/completions`,
    init: { method: "POST", headers, body: JSON.stringify(body) },
  };
}

/**
 * Build the coordinator request with the self-route opt-in. Sends BOTH
 * `Authorization: Bearer` (for a raw coordinator `/v1/chat/completions`) and
 * `x-api-key` (for the Next.js `/api/chat` proxy, which reads x-api-key and
 * re-emits Authorization upstream) so the same call works against either URL.
 */
export function buildCoordinatorRequest(
  cfg: Pick<FallbackConfig, "coordinatorURL" | "coordinatorApiKey">,
  body: unknown
): { url: string; init: RequestInit } {
  return {
    url: cfg.coordinatorURL,
    init: {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${cfg.coordinatorApiKey}`,
        "x-api-key": cfg.coordinatorApiKey,
        "X-Darkbloom-Route": "self",
      },
      body: JSON.stringify(body),
    },
  };
}

/**
 * POST a chat-completion request, preferring the local endpoint and falling
 * back to the coordinator self-route on a connection failure. Returns the
 * Response (stream it as usual) plus which path served it.
 */
export async function chatCompletionWithFallback(
  body: unknown,
  cfg: FallbackConfig,
  fetchImpl: typeof fetch = fetch
): Promise<FallbackResult> {
  if (cfg.local) {
    const { url, init } = buildLocalRequest(cfg.local, body);
    try {
      const response = await fetchImpl(url, init);
      // Reachable (even if it returns an HTTP error): use it, don't reroute.
      return { response, via: "local" };
    } catch {
      // Connection-level failure → fall through to the coordinator.
    }
  }
  const { url, init } = buildCoordinatorRequest(cfg, body);
  const response = await fetchImpl(url, init);
  return { response, via: "coordinator" };
}
