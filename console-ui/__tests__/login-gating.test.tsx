import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatInput } from "@/components/ChatInput";
import { ApiKeysManager } from "@/components/api-keys/ApiKeysManager";

// Regression tests for the Codex review finding: with Privy lazy-loaded, the
// auth context exposes a no-op `login` until `ready` flips. Sign-in CTAs must
// gate on `ready` so a user can't click them during the lazy-load window and
// get nothing (a dead click).
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

// Controllable auth state for the api-keys hook (ApiKeysManager's data source).
const apiKeys = vi.hoisted(() => ({
  ready: false,
  authenticated: false,
  login: (() => {}) as () => void,
}));
vi.mock("@/components/api-keys/useApiKeys", () => ({
  useApiKeys: () => ({
    keys: [],
    models: [],
    loading: false,
    error: null,
    submitting: false,
    busyId: null,
    consoleKeyId: null,
    reload: vi.fn(),
    createKey: vi.fn(),
    editKey: vi.fn(),
    toggleKey: vi.fn(),
    rotateKey: vi.fn(),
    deleteKey: vi.fn(),
    adoptConsoleKey: vi.fn(),
    authenticated: apiKeys.authenticated,
    ready: apiKeys.ready,
    login: apiKeys.login,
  }),
}));

describe("ChatInput sign-in gating (Codex review)", () => {
  const baseProps = {
    onSend: vi.fn(),
    onStop: vi.fn(),
    isStreaming: false,
    authenticated: false,
  };

  it("disables the sign-in CTA while auth is not ready (login would be a no-op)", () => {
    const onLogin = vi.fn();
    render(<ChatInput {...baseProps} onLogin={onLogin} ready={false} />);
    const btn = screen.getByRole("button", { name: /loading/i });
    expect(btn).toBeDisabled();
    fireEvent.click(btn);
    expect(onLogin).not.toHaveBeenCalled();
  });

  it("enables the sign-in CTA once auth is ready and forwards the click", () => {
    const onLogin = vi.fn();
    render(<ChatInput {...baseProps} onLogin={onLogin} ready={true} />);
    const btn = screen.getByRole("button", { name: /sign in to start chatting/i });
    expect(btn).not.toBeDisabled();
    fireEvent.click(btn);
    expect(onLogin).toHaveBeenCalledTimes(1);
  });
});

describe("ApiKeysManager sign-in gating (Codex review)", () => {
  it("disables the sign-in CTA while auth is not ready (login would be a no-op)", () => {
    const login = vi.fn();
    apiKeys.ready = false;
    apiKeys.authenticated = false;
    apiKeys.login = login;
    render(<ApiKeysManager />);
    const btn = screen.getByRole("button", { name: /loading/i });
    expect(btn).toBeDisabled();
    fireEvent.click(btn);
    expect(login).not.toHaveBeenCalled();
  });

  it("enables the sign-in CTA once auth is ready and forwards the click", () => {
    const login = vi.fn();
    apiKeys.ready = true;
    apiKeys.authenticated = false;
    apiKeys.login = login;
    render(<ApiKeysManager />);
    const btn = screen.getByRole("button", { name: /^sign in$/i });
    expect(btn).not.toBeDisabled();
    fireEvent.click(btn);
    expect(login).toHaveBeenCalledTimes(1);
  });
});
