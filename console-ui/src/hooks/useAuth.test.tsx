import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, cleanup, renderHook } from "@testing-library/react";
import type { AuthState } from "@/components/app-providers/PrivyClientProvider";
import { useAuth } from "./useAuth";
import { STORAGE_KEYS } from "@/lib/storage-keys";

const h = vi.hoisted(() => ({ auth: null as unknown as AuthState }));
vi.mock("@/components/app-providers/PrivyClientProvider", () => ({ useAuthContext: () => h.auth }));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

beforeEach(() => {
  localStorage.clear();
  vi.stubGlobal("fetch", vi.fn());
  h.auth = { ready: true, authenticated: true, user: { id: "u1" }, login: vi.fn(), logout: vi.fn(async () => {}), getAccessToken: vi.fn(async () => "privy-token") };
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("useAuth session identity", () => {
  it("readies a fresh account without minting keys across shared mounts", () => {
    for (let i = 0; i < 6; i++) {
      const { result } = renderHook(() => useAuth());
      expect(result.current.sessionReady).toBe(true);
    }
    expect(fetch).not.toHaveBeenCalled();
    expect(h.auth.getAccessToken).not.toHaveBeenCalled();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
  });
  it.each([{ ready: false }, { authenticated: false }])("waits for a ready authenticated session: %j", (state) => {
    Object.assign(h.auth, state);
    expect(renderHook(() => useAuth()).result.current.sessionReady).toBe(false);
  });
  it("migrates a legacy key without giving it explicit selected-key status", () => {
    localStorage.setItem(STORAGE_KEYS.legacyApiKey, "legacy");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "stale");
    renderHook(() => useAuth());
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("legacy");
    expect(localStorage.getItem(STORAGE_KEYS.consoleKeyId)).toBeNull();
    expect(fetch).not.toHaveBeenCalled();
  });
  it("does not replace an explicit restricted key on an expiry event", () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "restricted");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "selected");
    renderHook(() => useAuth());
    window.dispatchEvent(new Event("darkbloom-key-expired"));
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("restricted");
    expect(fetch).not.toHaveBeenCalled();
  });
  it("clears keys on logout without saving the session token", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "restricted");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "selected");
    const { result } = renderHook(() => useAuth());
    await act(() => result.current.logout());
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
    expect(localStorage.getItem(STORAGE_KEYS.consoleKeyId)).toBeNull();
    expect(h.auth.logout).toHaveBeenCalledOnce();
    expect(JSON.stringify(Array.from({ length: localStorage.length }, (_, index) => localStorage.getItem(localStorage.key(index)!)))).not.toContain("privy-token");
  });
});
