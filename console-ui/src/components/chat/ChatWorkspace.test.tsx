import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ChatPage from "@/app/page";
import { ChatInput } from "@/components/ChatInput";
import { ChatModelSelector } from "./ChatModelSelector";
import { useStore } from "@/lib/store";
import type { Model } from "@/lib/api";

const mocks = vi.hoisted(() => ({
  send: vi.fn(),
  stop: vi.fn(),
  retry: vi.fn(),
  auth: { authenticated: true, apiKeyReady: true, ready: true, login: vi.fn() },
}));
const models: Model[] = [
  { id: "test/text", object: "model", display_name: "Text model", input_modalities: ["text"] },
  { id: "test/vision", object: "model", display_name: "Vision model", input_modalities: ["text", "image"] },
];
const SEND_LABEL = "Send message";
const EDITED_PROMPT = "Help me debug this Swift function.";
const SAVED_DRAFT = "Keep this draft.";
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => mocks.auth }));
vi.mock("@/hooks/useChatStream", () => ({
  useChatStream: () => ({ isStreaming: false, handleSend: mocks.send, handleStop: mocks.stop, handleRetry: mocks.retry }),
}));
vi.mock("@/lib/api", () => ({ fetchModels: () => Promise.resolve(models) }));
vi.mock("@/components/TopBar", () => ({ TopBar: () => null }));
vi.mock("@/components/PreSendTrustBanner", () => ({ PreSendTrustBanner: () => null }));
vi.mock("@/components/InviteCodeBanner", () => ({ InviteCodeBanner: () => null }));

beforeEach(() => {
  vi.clearAllMocks();
  mocks.auth.authenticated = true;
  mocks.auth.apiKeyReady = true;
  useStore.setState({ chats: [], activeChatId: null, selectedModel: models[0].id, models, useMyMachine: false });
});
afterEach(cleanup);

describe("Chat workspace", () => {
  it("puts a suggested prompt in an editable draft without sending it", async () => {
    render(<ChatPage />);
    await act(async () => {});
    fireEvent.click(screen.getByRole("button", { name: "Work through code" }));
    const message = screen.getByRole("textbox", { name: "Message" });
    expect(message).toHaveFocus();
    expect((message as HTMLTextAreaElement).value).toContain("coding problem");
    expect(mocks.send).not.toHaveBeenCalled();

    fireEvent.change(message, { target: { value: EDITED_PROMPT } });
    fireEvent.click(screen.getByRole("button", { name: SEND_LABEL }));
    expect(mocks.send).toHaveBeenCalledWith(EDITED_PROMPT, []);
    expect(message).toHaveValue("");
  });

  it("preserves a draft until the account is ready to send", () => {
    const props = { onSend: mocks.send, onStop: mocks.stop, isStreaming: false };
    const { rerender } = render(<ChatInput {...props} submitReady={false} />);
    const message = screen.getByRole("textbox", { name: "Message" });
    fireEvent.change(message, { target: { value: SAVED_DRAFT } });
    fireEvent.keyDown(message, { key: "Enter" });
    expect(mocks.send).not.toHaveBeenCalled();
    expect(message).toHaveValue(SAVED_DRAFT);
    expect(screen.getByRole("button", { name: SEND_LABEL })).toBeDisabled();
    rerender(<ChatInput {...props} submitReady />);
    fireEvent.click(screen.getByRole("button", { name: SEND_LABEL }));
    expect(mocks.send).toHaveBeenCalledWith(SAVED_DRAFT, []);
  });

  it("does not submit when Enter confirms an IME composition or inserts a new line", () => {
    render(<ChatInput onSend={mocks.send} onStop={mocks.stop} isStreaming={false} />);
    const message = screen.getByRole("textbox", { name: "Message" });
    fireEvent.change(message, { target: { value: "こんにちは" } });
    fireEvent.keyDown(message, { key: "Enter", isComposing: true });
    fireEvent.keyDown(message, { key: "Enter", keyCode: 229 });
    fireEvent.keyDown(message, { key: "Enter", shiftKey: true });
    expect(mocks.send).not.toHaveBeenCalled();
    fireEvent.keyDown(message, { key: "Enter" });
    expect(mocks.send).toHaveBeenCalledWith("こんにちは", []);
  });

  it("keeps stop available while streaming", () => {
    render(<ChatInput onSend={mocks.send} onStop={mocks.stop} isStreaming />);
    fireEvent.click(screen.getByRole("button", { name: "Stop generating" }));
    expect(mocks.stop).toHaveBeenCalledOnce();
    expect(screen.queryByRole("button", { name: SEND_LABEL })).not.toBeInTheDocument();
  });

  it("filters models, supports arrow navigation, and restores focus on selection or Escape", async () => {
    render(<ChatModelSelector />);
    const trigger = screen.getByRole("button", { name: "Choose model: Text model" });
    fireEvent.click(trigger);
    const search = screen.getByRole("textbox", { name: "Search models" });
    expect(search).toHaveFocus();
    fireEvent.change(search, { target: { value: "vision" } });
    expect(screen.queryByRole("button", { name: "Text model Text" })).not.toBeInTheDocument();
    fireEvent.keyDown(search, { key: "ArrowDown" });
    const option = screen.getByRole("button", { name: "Vision model Text and images" });
    expect(option).toHaveFocus();
    fireEvent.click(option);
    expect(useStore.getState().selectedModel).toBe(models[1].id);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await waitFor(() => expect(trigger).toHaveFocus());

    fireEvent.click(trigger);
    fireEvent.keyDown(screen.getByRole("textbox", { name: "Search models" }), { key: "Escape" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });
});
