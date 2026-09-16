import { beforeEach, describe, expect, it } from "vitest";
import { useStore, type Chat, type Message } from "@/lib/store";

const message = (id: string, content: string): Message => ({ id, content, role: "assistant", timestamp: 0 });

beforeEach(() => {
  localStorage.clear();
  useStore.setState({ chats: [], activeChatId: null });
});

describe("chat message state", () => {
  it("preserves other chats and messages while applying updates and ordered token batches", () => {
    const untouched = message("other", "untouched");
    const otherChat: Chat = { id: "other-chat", title: "Other", createdAt: 0, messages: [message("reply", "other chat")] };
    useStore.setState({ chats: [
      { id: "active", title: "Active", createdAt: 0, messages: [message("reply", "Hello"), untouched] },
      otherChat,
    ] });
    const actions = useStore.getState();
    actions.appendToMessage("active", "reply", " world");
    actions.appendToThinking("active", "reply", "First");
    actions.appendToThinking("active", "reply", " second");
    actions.updateMessage("active", "reply", { streaming: false, tokenCount: 3 });
    const chats = useStore.getState().chats;
    expect(chats[0].messages[0]).toMatchObject({ content: "Hello world", thinking: "First second", streaming: false, tokenCount: 3 });
    expect(chats[0].messages[1]).toBe(untouched);
    expect(chats[1]).toBe(otherChat);
  });

  it("does not create messages for unknown chat or message identifiers", () => {
    const chat: Chat = { id: "active", title: "Active", createdAt: 0, messages: [message("reply", "keep")] };
    useStore.setState({ chats: [chat] });
    useStore.getState().appendToMessage("missing", "reply", "lost");
    useStore.getState().updateMessage("active", "missing", { content: "lost" });
    expect(useStore.getState().chats).toEqual([chat]);
  });

  it("keeps images and streaming in memory but excludes them from persisted history", () => {
    const id = useStore.getState().createChat();
    useStore.getState().addMessage(id, { ...message("reply", "visible"), streaming: true, images: ["data:image/png;base64,AAA"] });
    useStore.getState().appendToMessage(id, "reply", " token");
    const current = useStore.getState().chats[0].messages[0];
    expect(current.streaming).toBe(true);
    expect(current.images).toHaveLength(1);
    const persisted = JSON.parse(localStorage.getItem("darkbloom-store")!).state.chats[0].messages[0];
    expect(persisted).toMatchObject({ content: "visible token", streaming: false });
    expect(persisted.images).toBeUndefined();
  });
});
