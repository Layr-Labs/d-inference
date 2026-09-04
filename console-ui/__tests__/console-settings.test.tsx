import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useConsoleSettings } from "@/app/settings/useConsoleSettings";
import { STORAGE_KEYS } from "@/lib/constants";
import { apiExampleUrl } from "@/lib/api-example-url";
import { PUBLIC_COORDINATOR_URL } from "@/lib/coordinator-url";

const { addToast } = vi.hoisted(() => ({ addToast: vi.fn() }));
vi.mock("@/hooks/useToast", () => ({ useToastStore: () => addToast }));

const savedUrl = "https://example.test";
const sdkUrl = "https://sdk.example.test";

beforeEach(() => {
  localStorage.clear();
  localStorage.setItem(STORAGE_KEYS.apiExampleUrl, savedUrl);
  addToast.mockClear();
});

afterEach(() => vi.unstubAllGlobals());

describe("console settings", () => {
  it.each([
    "javascript:alert(1)",
    "mailto:hello@example.test",
    "https://user:secret@example.test",
    "https://example.test?token=secret",
    "https://example.test#fragment",
  ])("does not overwrite the saved URL with an invalid base URL: %s", (url) => {
    const { result } = renderHook(() => useConsoleSettings());
    act(() => result.current.updateExampleUrl(url));
    act(() => result.current.handleSave());
    expect(localStorage.getItem(STORAGE_KEYS.apiExampleUrl)).toBe(savedUrl);
    expect(result.current.hasChanges).toBe(true);
    expect(addToast).toHaveBeenCalledWith(expect.stringContaining("HTTP or HTTPS base URL"), "error");
  });

  it("saves a normalized HTTP base URL and clears the unsaved state", () => {
    const { result } = renderHook(() => useConsoleSettings());
    act(() => result.current.updateExampleUrl("  http://localhost:8080/  "));
    act(() => result.current.handleSave());
    expect(localStorage.getItem(STORAGE_KEYS.apiExampleUrl)).toBe("http://localhost:8080");
    expect(result.current.exampleUrl).toBe("http://localhost:8080");
    expect(result.current.hasChanges).toBe(false);
    expect(result.current.saved).toBe(true);
  });

  it("saves examples without changing the coordinator override or encryption cache", () => {
    const coordinatorOverride = "https://coordinator.example.test";
    const keyCache = JSON.stringify({ [coordinatorOverride]: { kid: "key-123", publicKeyB64: "cached-key", fetchedAt: 123 } });
    localStorage.setItem(STORAGE_KEYS.coordinatorUrl, coordinatorOverride);
    localStorage.setItem("darkbloom_coord_enc_key_v2", keyCache);
    const { result } = renderHook(() => useConsoleSettings());
    act(() => result.current.updateExampleUrl(sdkUrl));
    act(() => result.current.handleSave());
    expect(apiExampleUrl()).toBe(sdkUrl);
    expect(localStorage.getItem(STORAGE_KEYS.coordinatorUrl)).toBe(coordinatorOverride);
    expect(localStorage.getItem("darkbloom_coord_enc_key_v2")).toBe(keyCache);
  });

  it("retains the saved example URL after auth removes the legacy coordinator override", () => {
    localStorage.setItem(STORAGE_KEYS.coordinatorUrl, "https://legacy.example.test");
    const settings = renderHook(() => useConsoleSettings());
    act(() => settings.result.current.updateExampleUrl(sdkUrl));
    act(() => settings.result.current.handleSave());
    settings.unmount();
    localStorage.removeItem(STORAGE_KEYS.coordinatorUrl);
    const remounted = renderHook(() => useConsoleSettings());
    expect(remounted.result.current.exampleUrl).toBe(sdkUrl);
    expect(apiExampleUrl()).toBe(sdkUrl);
  });

  it("defaults examples to the public URL rather than the coordinator override", () => {
    localStorage.removeItem(STORAGE_KEYS.apiExampleUrl);
    localStorage.setItem(STORAGE_KEYS.coordinatorUrl, "https://legacy.example.test");
    expect(apiExampleUrl()).toBe(PUBLIC_COORDINATOR_URL);
  });

  it("resolves a safe example default without browser storage during server rendering", () => {
    vi.stubGlobal("window", undefined);
    expect(apiExampleUrl()).toBe(PUBLIC_COORDINATOR_URL);
  });

  it("checks the console proxy even when a different example URL is saved or being edited", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, json: async () => ({ status: "ok", providers: 2 }) });
    vi.stubGlobal("fetch", fetchMock);
    const { result } = renderHook(() => useConsoleSettings());
    act(() => result.current.updateExampleUrl("https://unsaved.example.test"));
    await act(async () => { await result.current.handleHealthCheck(); });
    expect(fetchMock).toHaveBeenCalledWith("/api/health", expect.any(Object));
    expect(localStorage.getItem(STORAGE_KEYS.apiExampleUrl)).toBe(savedUrl);
    expect(result.current.healthStatus).toBe("ok");
    expect(result.current.healthInfo).toBe("Connected, 2 providers online");
  });

  it("surfaces a failed health check without reporting the service as connected", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({ ok: false, status: 503 }));
    const { result } = renderHook(() => useConsoleSettings());
    await act(async () => { await result.current.handleHealthCheck(); });
    expect(result.current.healthStatus).toBe("error");
    expect(result.current.healthInfo).toBe("Health check failed: 503");
  });
});
