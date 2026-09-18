import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useChatStream } from "./useChatStream";
import { useStore } from "@/lib/store";
import { STORAGE_KEYS } from "@/lib/storage-keys";
import type { StreamCallbacks } from "@/lib/api/types";

const h = vi.hoisted(() => ({ auth: { authenticated: true, user: { id: "one" }, getAccessToken: vi.fn() }, stream: vi.fn() }));
vi.mock("@/components/app-providers/PrivyClientProvider", () => ({ useAuthContext: () => h.auth }));
vi.mock("@/lib/api", () => ({ streamChat: h.stream }));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));
beforeEach(() => {
  vi.clearAllMocks(); localStorage.clear();
  h.auth.authenticated = true; h.auth.user = { id: "one" };
  h.auth.getAccessToken.mockResolvedValue("session-one");
  h.stream.mockImplementation(async (_m, _model, cb: StreamCallbacks) => { cb.onError("trial error"); });
  useStore.setState({ chats: [], activeChatId: null, selectedModel: "bonsai", useMyMachine: false });
});
afterEach(cleanup);

describe("chat session lifecycle", () => {
  it("fetches a fresh token for every send and retry; both display the trial error", async () => {
    const { result } = renderHook(() => useChatStream());
    await act(() => result.current.handleSend("hello"));
    const reply = useStore.getState().chats[0].messages[1];
    expect(reply.content).toBe("Error: trial error");
    expect(h.stream.mock.calls[0][4].auth).toEqual({ kind: "session", token: "session-one" });
    h.auth.getAccessToken.mockResolvedValue("rotated-token");
    await act(async () => result.current.handleRetry(reply.id));
    expect(h.stream.mock.calls[1][4].auth).toEqual({ kind: "session", token: "rotated-token" });
    expect(h.auth.getAccessToken).toHaveBeenCalledTimes(2);
    expect(useStore.getState().chats[0].messages[1].content).toBe("Error: trial error");
  });
  it("cannot fall back to a saved key after token acquisition fails", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "saved-key");
    h.auth.getAccessToken.mockRejectedValue(new Error("expired"));
    const { result } = renderHook(() => useChatStream());
    await act(() => result.current.handleSend("hello"));
    expect(h.stream).not.toHaveBeenCalled();
    expect(useStore.getState().chats[0].messages[1].content).toContain("Session expired");
  });
  it("keeps a tracked key's identity and owner routing in explicit key mode", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "restricted");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key-id");
    useStore.setState({ useMyMachine: true });
    const { result } = renderHook(() => useChatStream("api-key"));
    await act(() => result.current.handleSend("hello"));
    expect(h.auth.getAccessToken).not.toHaveBeenCalled();
    expect(h.stream.mock.calls[0][4]).toEqual({ selfRoute: true, auth: { kind: "api-key", key: "restricted" } });
  });
  it("does not fall back to session when the selected key is revoked", async () => {
    const { result } = renderHook(() => useChatStream("api-key"));
    await act(() => result.current.handleSend("hello"));
    expect(h.stream).not.toHaveBeenCalled();
    expect(h.auth.getAccessToken).not.toHaveBeenCalled();
  });
  it("aborts stale token acquisition and clears history on account switch", async () => {
    let release!: (token: string) => void;
    h.auth.getAccessToken.mockImplementation(() => new Promise<string>((resolve) => { release = resolve; }));
    const { result, rerender } = renderHook(() => useChatStream());
    let pending!: Promise<void>;
    act(() => { pending = result.current.handleSend("private message"); });
    h.auth.user = { id: "two" }; rerender();
    await act(async () => { release("token-for-new-account"); await pending; });
    expect(h.stream).not.toHaveBeenCalled();
    expect(useStore.getState().chats).toEqual([]);
  });
  it("clears the old account's selected key on direct account switch without session fallback", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "old-account-key");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "old-id");
    const { result, rerender } = renderHook(() => useChatStream("api-key"));
    h.auth.user = { id: "two" }; rerender();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
    await act(() => result.current.handleSend("hello"));
    expect(h.stream).not.toHaveBeenCalled();
    expect(h.auth.getAccessToken).not.toHaveBeenCalled();
    expect(useStore.getState().chats[0].messages[1].content).toContain("Select an API key");
  });
  it("preserves the saved explicit key during initial auth hydration", () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "this-account-key");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "this-id");
    h.auth.authenticated = false;
    const { rerender } = renderHook(() => useChatStream("api-key"));
    h.auth.authenticated = true; rerender();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("this-account-key");
  });
  it("stop prevents a pending token from sending and never replays the request", async () => {
    let release!: (token: string) => void;
    h.auth.getAccessToken.mockImplementation(() => new Promise<string>((resolve) => { release = resolve; }));
    const { result } = renderHook(() => useChatStream());
    let pending!: Promise<void>;
    act(() => { pending = result.current.handleSend("hello"); });
    act(() => result.current.handleStop());
    await act(async () => { release("fresh-token"); await pending; });
    expect(h.stream).not.toHaveBeenCalled();
    expect(result.current.isStreaming).toBe(false);
  });
  it("ignores late stream callbacks after logout", async () => {
    let callbacks!: StreamCallbacks;
    h.stream.mockImplementation(async (_m, _model, cb: StreamCallbacks) => { callbacks = cb; });
    const { result, rerender } = renderHook(() => useChatStream());
    await act(() => result.current.handleSend("private message"));
    h.auth.authenticated = false; rerender();
    act(() => callbacks.onError("private late error"));
    expect(useStore.getState().chats).toEqual([]);
    await waitFor(() => expect(result.current.isStreaming).toBe(false));
  });
});
