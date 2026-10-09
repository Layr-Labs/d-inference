import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, waitFor, act } from "@testing-library/react";
import { useLeaderboard } from "./useLeaderboard";
import type { LeaderboardResponse } from "./types";

function response(metric: string): LeaderboardResponse {
  return {
    metric,
    window: "24h",
    entries: [
      {
        rank: 1,
        pseudonym: "swift-otter-42",
        earnings_micro_usd: 2_000_000,
        work_earnings_micro_usd: 1_500_000,
        reward_earnings_micro_usd: 500_000,
        tokens: 1_000_000,
        jobs: 10,
      },
    ],
    updated_at: "2026-07-01T00:00:00Z",
  };
}

describe("useLeaderboard", () => {
  const fetchMock = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("fetch", fetchMock);
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    fetchMock.mockReset();
  });

  it("loads the earnings ranking with a fixed 24h window", async () => {
    fetchMock.mockResolvedValue({ ok: true, json: async () => response("earnings") });

    const { result } = renderHook(() => useLeaderboard());
    expect(result.current.loading).toBe(true);

    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBeNull();
    expect(result.current.leaderboard?.entries).toHaveLength(1);

    const url = new URL(fetchMock.mock.calls[0][0], "http://localhost");
    expect(url.pathname).toBe("/api/leaderboard");
    expect(url.searchParams.get("metric")).toBe("earnings");
    expect(url.searchParams.get("window")).toBe("24h");
  });

  it("refetches when the metric changes", async () => {
    fetchMock.mockResolvedValue({ ok: true, json: async () => response("earnings") });

    const { result } = renderHook(() => useLeaderboard());
    await waitFor(() => expect(result.current.loading).toBe(false));

    fetchMock.mockResolvedValue({ ok: true, json: async () => response("tokens") });
    act(() => result.current.setMetric("tokens"));

    await waitFor(() => expect(result.current.leaderboard?.metric).toBe("tokens"));
    const lastUrl = new URL(fetchMock.mock.calls.at(-1)![0], "http://localhost");
    expect(lastUrl.searchParams.get("metric")).toBe("tokens");
    expect(lastUrl.searchParams.get("window")).toBe("24h");
  });

  it("surfaces HTTP errors", async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 503, json: async () => ({}) });

    const { result } = renderHook(() => useLeaderboard());
    await waitFor(() => expect(result.current.loading).toBe(false));
    expect(result.current.error).toBe("Leaderboard HTTP 503");
    expect(result.current.leaderboard).toBeNull();
  });
});
