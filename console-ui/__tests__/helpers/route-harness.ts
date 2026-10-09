import { vi, beforeEach, afterEach } from "vitest";
import { NextRequest } from "next/server";

// Shared harness for Next.js API route-handler tests. Route handlers forward
// to the coordinator with global fetch, so each test stubs fetch first and
// then dynamically imports the route module.

export const DEFAULT_COORD = "https://api.darkbloom.dev";

export interface UpstreamFetchHolder {
  fetch: ReturnType<typeof vi.fn>;
}

/**
 * Installs a fresh global-fetch stub before each test and restores mocks +
 * resets the module registry after each test. Returns a holder whose `fetch`
 * property always points at the current test's stub.
 */
export function stubUpstreamFetch(): UpstreamFetchHolder {
  const holder: UpstreamFetchHolder = { fetch: vi.fn() };
  beforeEach(() => {
    holder.fetch = vi.fn();
    vi.stubGlobal("fetch", holder.fetch);
  });
  afterEach(() => {
    vi.restoreAllMocks();
    vi.resetModules();
  });
  return holder;
}

/** Builds a synthetic NextRequest against the local origin. */
export function makeRequest(
  url: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string }
): NextRequest {
  return new NextRequest(new URL(url, "http://localhost:3000"), {
    method: init?.method ?? "GET",
    headers: init?.headers ?? {},
    ...(init?.body ? { body: init.body } : {}),
  });
}

export function upstreamJson(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function upstreamOk(body: unknown): Response {
  return upstreamJson(200, body);
}

export function upstreamError(status: number, body = "error"): Response {
  return new Response(body, { status });
}
