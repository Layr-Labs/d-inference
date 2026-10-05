import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useChatStream } from "./useChatStream";
import { useStore } from "@/lib/store";
import { useToastStore } from "./useToast";
import { setEncryptionEnabled } from "@/lib/encryption";

vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

beforeEach(() => {
  localStorage.clear();
  setEncryptionEnabled(false);
  useStore.setState({ chats: [], activeChatId: null, selectedModel: "fixture-vision-model", models: [], useMyMachine: false });
  useToastStore.setState({ toasts: [] });
  vi.stubGlobal("fetch", vi.fn(async () => new Response("data: [DONE]\n\n", { headers: { "content-type": "text/event-stream" } })));
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  useStore.setState({ chats: [], activeChatId: null });
  useToastStore.setState({ toasts: [] });
});

describe("chat send and retry budget lifecycle", () => {
  it("retains user images and text when send and retry are refused locally", async () => {
    const data = `data:image/jpeg;base64,${Buffer.alloc(7 * 1024 * 1024).toString("base64")}`;
    const images = [data, data];
    const text = "describe my images";
    const { result } = renderHook(() => useChatStream());
    await act(async () => { await result.current.handleSend(text, images); });
    const messages = useStore.getState().chats[0].messages;
    expect(messages[0].content).toBe(text);
    expect(messages[0].images).toEqual(images);
    expect(messages[1].error).toBe(true);
    expect(messages[1].streaming).toBe(false);
    expect(messages[1].content).toMatch(/too large/i);
    expect(result.current.isStreaming).toBe(false);
    expect(fetch).not.toHaveBeenCalled();
    expect(useToastStore.getState().toasts).toHaveLength(1);

    act(() => result.current.handleRetry(messages[1].id));
    await waitFor(() => expect(result.current.isStreaming).toBe(false));
    const retried = useStore.getState().chats[0].messages;
    expect(retried).toHaveLength(2);
    expect(retried[0].content).toBe(text);
    expect(retried[0].images).toEqual(images);
    expect(retried[1].error).toBe(true);
    expect(retried[1].streaming).toBe(false);
    expect(retried[1].content).toMatch(/too large/i);
    expect(useToastStore.getState().toasts).toHaveLength(2);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("keeps newest-image history pruning and permits a valid send", async () => {
    const chatId = useStore.getState().createChat();
    const oldImage = `data:image/jpeg;base64,${Buffer.alloc(10 * 1024 * 1024).toString("base64")}`;
    useStore.getState().addMessage(chatId, { id: "old", role: "user", content: "old image", images: [oldImage], timestamp: 0 });
    const currentImage = "data:image/png;base64,AQID";
    const { result } = renderHook(() => useChatStream());
    await act(async () => { await result.current.handleSend("new image", [currentImage]); });
    expect(fetch).toHaveBeenCalledTimes(1);
    const [, init] = vi.mocked(fetch).mock.calls[0];
    const sent = JSON.parse(init?.body as string);
    expect(sent.messages[0].role).toBe("system");
    expect(sent.messages[1]).toEqual({ role: "user", content: "old image" });
    expect(JSON.stringify(sent)).not.toContain(oldImage);
    expect(JSON.stringify(sent)).toContain(currentImage);
    expect(useStore.getState().chats[0].messages[0].images).toEqual([oldImage]);
    expect(result.current.isStreaming).toBe(false);
    expect(useToastStore.getState().toasts).toHaveLength(0);
  });

  it("rechecks current encryption and model settings with pruned retry history", async () => {
    const chatId = useStore.getState().createChat();
    const oldImage = "data:image/png;base64,AQID";
    useStore.getState().addMessage(chatId, { id: "old", role: "user", content: "old image", images: [oldImage], timestamp: 0 });
    const currentImage = `data:image/jpeg;base64,${Buffer.alloc(10 * 1024 * 1024).toString("base64")}`;
    const { result } = renderHook(() => useChatStream());
    await act(async () => { await result.current.handleSend("new image", [currentImage]); });
    const assistantId = useStore.getState().chats[0].messages[2].id;
    expect(fetch).toHaveBeenCalledTimes(1);

    vi.mocked(fetch).mockClear();
    setEncryptionEnabled(true);
    act(() => result.current.handleRetry(assistantId));
    await waitFor(() => expect(result.current.isStreaming).toBe(false));
    expect(fetch).not.toHaveBeenCalled();
    expect(useStore.getState().chats[0].messages[2].content).toMatch(/too large/i);
    expect(useStore.getState().chats[0].messages[1].images).toEqual([currentImage]);

    setEncryptionEnabled(false);
    useStore.setState({ selectedModel: "current-retry-model" });
    act(() => result.current.handleRetry(assistantId));
    await waitFor(() => expect(result.current.isStreaming).toBe(false));
    expect(fetch).toHaveBeenCalledTimes(1);
    const sent = JSON.parse(vi.mocked(fetch).mock.calls[0][1]?.body as string);
    expect(sent.model).toBe("current-retry-model");
    expect(sent.messages[0].role).toBe("system");
    expect(sent.messages[1]).toEqual({ role: "user", content: "old image" });
    expect(JSON.stringify(sent)).not.toContain(oldImage);
    expect(JSON.stringify(sent)).toContain(currentImage);
    expect(useStore.getState().chats[0].messages[2].error).toBe(false);
  });
});
