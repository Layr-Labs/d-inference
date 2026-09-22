import { act, cleanup, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useStore } from "@/lib/store";
import { streamChat } from "@/lib/api";
import { useChatStream } from "./useChatStream";

vi.mock("@/lib/api", () => ({ streamChat: vi.fn().mockResolvedValue(undefined) }));

beforeEach(() => {
  vi.clearAllMocks();
  useStore.setState({ selectedModel: "native", models: [
    { id: "native", object: "model", output_modalities: ["decision"] },
    { id: "chat", object: "model" },
  ], chats: [], activeChatId: null });
});
afterEach(cleanup);

describe("chat request capability guard", () => {
  it("does not create or send a chat for a stale decision-only selection", async () => {
    const { result } = renderHook(useChatStream);
    await act(async () => { await result.current.handleSend("Hello"); });
    expect(streamChat).not.toHaveBeenCalled();
    expect(useStore.getState().chats).toEqual([]);
  });

  it("does not retry a saved conversation through the decision endpoint", () => {
    useStore.setState({ activeChatId: "saved", chats: [{ id: "saved", title: "Saved", createdAt: 0, messages: [
      { id: "user", role: "user", content: "Hello", timestamp: 0 },
      { id: "reply", role: "assistant", content: "Failed", error: true, timestamp: 0 },
    ] }] });
    const { result } = renderHook(useChatStream);
    act(() => { result.current.handleRetry("reply"); });
    expect(streamChat).not.toHaveBeenCalled();
    expect(useStore.getState().chats[0].messages[1].error).toBe(true);
  });
});
