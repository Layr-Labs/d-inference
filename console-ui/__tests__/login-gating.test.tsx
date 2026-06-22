import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatInput } from "@/components/ChatInput";

// Regression test for the Codex review finding: with Privy lazy-loaded, the
// auth context exposes a no-op `login` until `ready` flips. Sign-in CTAs must
// gate on `ready` so a user can't click them during the lazy-load window and
// get nothing.
vi.mock("@/lib/google-analytics", () => ({ trackEvent: vi.fn() }));

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
