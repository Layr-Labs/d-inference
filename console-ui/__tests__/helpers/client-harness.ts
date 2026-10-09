import { vi, beforeEach, afterEach } from "vitest";

// Shared harness for `@/lib/api` client-function tests: a per-test global
// fetch stub plus a minimal JSON Response builder.

export interface ClientFetchHolder {
  fetch: ReturnType<typeof vi.fn>;
}

/**
 * Installs a fresh global-fetch stub and clears localStorage before each
 * test; restores all mocks after. Returns a holder whose `fetch` property
 * always points at the current test's stub.
 */
export function stubClientFetch(): ClientFetchHolder {
  const holder: ClientFetchHolder = { fetch: vi.fn() };
  beforeEach(() => {
    holder.fetch = vi.fn();
    vi.stubGlobal("fetch", holder.fetch);
    localStorage.clear();
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });
  return holder;
}

/** Build a minimal Response mock for JSON responses. */
export function jsonResponse(body: unknown, status = 200): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
    headers: new Headers(),
  } as unknown as Response;
}
