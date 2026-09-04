import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { ProviderOnboarding } from "./ProviderOnboarding";
import { SetupCommand } from "./SetupCommand";

const { auth } = vi.hoisted(() => ({
  auth: { ready: true, authenticated: false, login: vi.fn() },
}));

vi.mock("@/components/providers/PrivyClientProvider", () => ({ useAuthContext: () => auth }));

beforeEach(() => {
  auth.ready = true;
  auth.authenticated = false;
  auth.login.mockReset();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe("ProviderOnboarding", () => {
  it("lets guests inspect setup and requirements before asking them to sign in", () => {
    render(<ProviderOnboarding />);

    expect(screen.getByRole("heading", { name: "Put your Mac to work." })).toBeInTheDocument();
    expect(screen.getByText("48 GB or more of unified memory")).toBeInTheDocument();
    expect(screen.getByText("macOS 26 or later")).toBeInTheDocument();
    expect(screen.getByLabelText("Install on your Mac command")).toHaveTextContent("curl -fsSL https://api.darkbloom.dev/install.sh | bash");
    expect(screen.getByRole("link", { name: "Open the earnings calculator" })).toHaveAttribute("href", "/earn");
    fireEvent.click(screen.getByRole("button", { name: "Sign in to link your Mac" }));
    expect(auth.login).toHaveBeenCalledTimes(1);
  });

  it("keeps setup usable while authentication initializes", () => {
    auth.ready = false;
    render(<ProviderOnboarding />);

    for (const button of screen.getAllByRole("button", { name: "Loading sign-in…" })) {
      expect(button).toBeDisabled();
    }
    expect(screen.getByRole("button", { name: "Copy command: Install on your Mac" })).toBeEnabled();
    expect(screen.getByRole("link", { name: "Already have a code? Enter it here" })).toHaveAttribute("href", "/link");
  });

  it("treats a returning provider's setup visit as adding another Mac", () => {
    auth.authenticated = true;
    render(<ProviderOnboarding hasLinkedProviders />);

    expect(screen.getByRole("heading", { name: "Add another Mac." })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Back to your providers" })).toHaveAttribute("href", "/providers");
    expect(screen.getByRole("link", { name: "Open provider dashboard" })).toHaveAttribute("href", "/providers");
    expect(screen.queryByRole("button", { name: /Sign in/ })).not.toBeInTheDocument();
    expect(screen.getByText(/A linked Mac may still be downloading models/)).toBeInTheDocument();
  });
});

describe("SetupCommand", () => {
  it("announces success only after the clipboard write succeeds", async () => {
    let finish!: () => void;
    const writeText = vi.fn(() => new Promise<void>((resolve) => { finish = resolve; }));
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
    render(<SetupCommand command="darkbloom login" label="Link account" />);

    fireEvent.click(screen.getByRole("button", { name: "Copy command: Link account" }));
    expect(screen.getByRole("button", { name: "Copying…: Link account" })).toBeDisabled();
    expect(screen.queryByText("Copied")).not.toBeInTheDocument();
    await act(async () => { finish(); });
    expect(writeText).toHaveBeenCalledWith("darkbloom login");
    expect(screen.getByRole("button", { name: "Copied: Link account" })).toBeEnabled();
  });

  it("keeps the command selectable and explains manual recovery if copying fails", async () => {
    const writeText = vi.fn().mockRejectedValue(new Error("Clipboard denied"));
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
    render(<SetupCommand command="darkbloom status" label="Check status" />);

    fireEvent.click(screen.getByRole("button", { name: "Copy command: Check status" }));
    expect(await screen.findByRole("status")).toHaveTextContent("Select the command and copy it manually");
    expect(screen.getByLabelText("Check status command")).toHaveAttribute("tabindex", "0");
    expect(screen.getByLabelText("Check status command")).toHaveTextContent("darkbloom status");
    expect(screen.queryByText("Copied")).not.toBeInTheDocument();
  });
});
