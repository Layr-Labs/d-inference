// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import type { AuthState } from "@/components/providers/PrivyClientProvider";
import { useAuth, resetConsoleKeyProvisionBackoff } from "./useAuth";
import { STORAGE_KEYS } from "@/lib/constants";

// Mutable holder so each test can drive what useAuthContext returns.
const h = vi.hoisted(() => ({ auth: null as unknown as AuthState }));

vi.mock("@/components/providers/PrivyClientProvider", () => ({
  useAuthContext: () => h.auth,
}));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

function authState(over: Partial<AuthState> = {}): AuthState {
  return {
    ready: true,
    authenticated: true,
    user: { id: "u1" },
    login: vi.fn(),
    logout: vi.fn(async () => {}),
    getAccessToken: vi.fn(async () => "privy-token"),
    ...over,
  };
}

// Let pending provision microtasks settle (fetch + json + finally/cooldown).
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

beforeEach(() => {
  localStorage.clear();
  resetConsoleKeyProvisionBackoff();
  h.auth = authState();
});

afterEach(() => {
  vi.unstubAllGlobals();
  resetConsoleKeyProvisionBackoff();
});

describe("useAuth console-key provisioning", () => {
  it("coalesces many concurrent mounts into a single POST /api/auth/keys", async () => {
    const fetchMock = vi.fn(async () => ({
      ok: true,
      json: async () => ({ api_key: "sk-db-new" }),
    }));
    vi.stubGlobal("fetch", fetchMock);

    // The provider dashboard mounts useAuth many times at once.
    for (let i = 0; i < 6; i++) renderHook(() => useAuth());

    await waitFor(() =>
      expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("sk-db-new"),
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/auth/keys",
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("does not call the endpoint when a key already exists", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "sk-db-existing");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    for (let i = 0; i < 4; i++) renderHook(() => useAuth());
    await flush();

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("backs off after a rate-limited response instead of storming", async () => {
    const fetchMock = vi.fn(async () => ({
      ok: false,
      status: 429,
      json: async () => ({ error: "rate limit exceeded" }),
    }));
    vi.stubGlobal("fetch", fetchMock);

    // First mount makes exactly one attempt, which fails and arms the cooldown.
    renderHook(() => useAuth());
    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    await flush();

    // Further mounts within the cooldown must NOT re-hit the endpoint.
    fetchMock.mockClear();
    for (let i = 0; i < 5; i++) renderHook(() => useAuth());
    await flush();

    expect(fetchMock).not.toHaveBeenCalled();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
  });
});
