import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import ChatPage from "./page";
import { useStore } from "@/lib/store";
import { STORAGE_KEYS } from "@/lib/storage-keys";
import { Sidebar } from "@/components/Sidebar";

const h = vi.hoisted(() => ({ getAccessToken: vi.fn(async () => "login-token") }));
vi.mock("@/components/app-providers/PrivyClientProvider", () => ({
  useAuthContext: () => ({ ready: true, authenticated: true, user: { id: "user-one" }, login: vi.fn(), logout: vi.fn(), getAccessToken: h.getAccessToken }),
}));
vi.mock("next/navigation", () => ({ usePathname: () => "/chat", useRouter: () => ({ push: vi.fn() }) }));
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));
const fetchMock = vi.fn();
const trialError = "Hey, you've used all 5 million free tokens for Bonsai 2. You can continue with a funded API key in the API Console.";

beforeEach(() => {
  localStorage.clear(); vi.clearAllMocks();
  // Plaintext is an existing explicit preference; sealed transport is tested separately.
  vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
  useStore.setState({ chats: [], activeChatId: null, models: [], selectedModel: "bonsai", useMyMachine: false });
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockImplementation(async (url: string) => {
    if (url === "/api/models") return Response.json({ data: [{ id: "bonsai", display_name: "Bonsai 2", object: "model", input_modalities: ["text"] }] });
    if (url.startsWith("/api/attestation")) return Response.json({ count: 0 });
    if (url === "/api/chat") return Response.json({ error: { code: "bonsai_trial_exhausted", message: trialError } }, { status: 402 });
    return Response.json({});
  });
});
afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("full chat page session readiness", () => {
  it("mounts shared components, loads models and sends without provisioning a key", async () => {
    render(<><Sidebar /><ChatPage /></>);
    await waitFor(() => expect(useStore.getState().models).toHaveLength(1));
    const message = screen.getByRole("textbox", { name: "Message" });
    fireEvent.change(message, { target: { value: "hello" } });
    expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    await waitFor(() => expect(screen.getByText(`Error: ${trialError}`)).toBeInTheDocument());
    expect(fetchMock.mock.calls.some(([url]) => url === "/api/auth/keys")).toBe(false);
    const chatCall = fetchMock.mock.calls.find(([url]) => url === "/api/chat");
    expect(chatCall?.[1].headers.Authorization).toBe("Bearer login-token");
    expect(chatCall?.[1].headers["x-api-key"]).toBeUndefined();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBeNull();
    expect(screen.queryByLabelText("Chat access")).not.toBeInTheDocument();
  });
  it("defaults an explicit restricted key to key mode and allows an intentional session switch", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "restricted-key");
    localStorage.setItem(STORAGE_KEYS.consoleKeyId, "key-id");
    render(<ChatPage />);
    const access = await screen.findByRole("combobox", { name: "Chat access" });
    expect(access).toHaveValue("api-key");
    fireEvent.change(access, { target: { value: "session" } });
    expect(access).toHaveValue("session");
    await act(async () => {});
    const modelCalls = fetchMock.mock.calls.filter(([url]) => url === "/api/models");
    expect(modelCalls.at(-1)?.[1].headers["x-api-key"]).toBeUndefined();
    expect(localStorage.getItem(STORAGE_KEYS.apiKey)).toBe("restricted-key");
  });
  it("ignores an untracked legacy key for default session mode and model discovery", async () => {
    localStorage.setItem(STORAGE_KEYS.apiKey, "untracked-key");
    render(<ChatPage />);
    await waitFor(() => expect(useStore.getState().models).toHaveLength(1));
    expect(screen.queryByLabelText("Chat access")).not.toBeInTheDocument();
    const modelCall = fetchMock.mock.calls.find(([url]) => url === "/api/models");
    expect(modelCall?.[1].headers["x-api-key"]).toBeUndefined();
  });
});
