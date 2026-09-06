// @vitest-environment jsdom
import { describe, it, expect, vi, afterEach } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { useStripePayouts } from "./useStripePayouts";

// Stub only the network edge (global fetch) — the real lib/api request and
// response handling runs.
function okJson(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

const READY_STATUS = {
  configured: true,
  has_account: true,
  status: "ready",
  min_withdraw_micro_usd: 1_000_000,
};

function fetchRouting(statusResponse: () => Response) {
  return async (url: RequestInfo | URL) => {
    const u = String(url);
    if (u.includes("/stripe/status")) return statusResponse();
    if (u.includes("/stripe/withdrawals")) return okJson({ withdrawals: [] });
    throw new Error(`unexpected fetch: ${u}`);
  };
}

function stubFetch(statusResponse: () => Response) {
  const mock = vi.fn(fetchRouting(statusResponse));
  vi.stubGlobal("fetch", mock);
  return mock;
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("useStripePayouts status errors", () => {
  it("flags a failed status fetch and recovers on reload", async () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const mock = stubFetch(() => new Response("boom", { status: 500 }));
    const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn() }));

    await waitFor(() => expect(result.current.statusError).toBe(true));
    expect(result.current.status).toBeNull();

    // Retry exactly as the hero's reload CTA does.
    mock.mockImplementation(fetchRouting(() => okJson(READY_STATUS)));
    result.current.reload();
    await waitFor(() => expect(result.current.statusError).toBe(false));
    expect(result.current.status?.status).toBe("ready");
  });

  it("starts without a status error and stays clean on success", async () => {
    stubFetch(() => okJson(READY_STATUS));
    const { result } = renderHook(() => useStripePayouts({ addToast: vi.fn() }));

    expect(result.current.statusError).toBe(false);
    await waitFor(() => expect(result.current.status).not.toBeNull());
    expect(result.current.statusError).toBe(false);
  });
});
