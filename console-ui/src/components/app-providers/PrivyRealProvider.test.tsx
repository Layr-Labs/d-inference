// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import type { AuthState } from "./PrivyClientProvider";

// Mutable holder for the value usePrivy() returns, so a test can simulate a
// Privy "tick" by swapping in a brand-new object with new function identities.
const h = vi.hoisted(() => ({ privy: null as unknown as Record<string, unknown>, appearance: {} as Record<string, unknown> }));

vi.mock("@privy-io/react-auth", () => ({
  PrivyProvider: (props: { children?: unknown; config: { appearance: Record<string, unknown> } }) => {
    h.appearance = props.config.appearance;
    return props.children;
  },
  usePrivy: () => h.privy,
}));

import PrivyRealProvider from "./PrivyRealProvider";
import { ThemeProvider, useTheme } from "./ThemeProvider";

function privyValue(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    ready: true,
    authenticated: true,
    user: { id: "u1" },
    login: vi.fn(),
    logout: vi.fn(async () => {}),
    getAccessToken: vi.fn(async () => "tok"),
    ...over,
  };
}

beforeEach(() => {
  h.privy = privyValue();
});
afterEach(() => vi.unstubAllGlobals());

describe("PrivyRealProvider auth identity stability", () => {
  it("matches the console appearance without republishing authentication", () => {
    localStorage.clear();
    vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
    function AppearanceControl() {
      const { setTheme } = useTheme();
      return <button onClick={() => setTheme("dark")}>Choose dark</button>;
    }
    const onAuthChange = vi.fn();
    render(<ThemeProvider><AppearanceControl /><PrivyRealProvider appId="x" onAuthChange={onAuthChange} /></ThemeProvider>);
    expect(h.appearance).toMatchObject({ theme: "light", accentColor: "#0b41ff" });
    const initialCalls = onAuthChange.mock.calls.length;
    fireEvent.click(screen.getByRole("button", { name: "Choose dark" }));
    expect(h.appearance).toMatchObject({ theme: "dark", accentColor: "#0b41ff" });
    expect(onAuthChange).toHaveBeenCalledTimes(initialCalls);
  });
  it("does not republish AuthState when only Privy's object identity changes", () => {
    const onAuthChange = vi.fn();
    const { rerender } = render(
      <PrivyRealProvider appId="x" onAuthChange={onAuthChange} />,
    );

    const callsAfterMount = onAuthChange.mock.calls.length;
    expect(callsAfterMount).toBeGreaterThan(0);

    // Simulate a token-refresh tick: new object + new function refs, but the
    // SAME ready/authenticated/user.id.
    h.privy = privyValue();
    rerender(<PrivyRealProvider appId="x" onAuthChange={onAuthChange} />);

    expect(onAuthChange).toHaveBeenCalledTimes(callsAfterMount);
  });

  it("publishes a stable getAccessToken across renders", () => {
    const states: AuthState[] = [];
    const onAuthChange = (s: AuthState) => states.push(s);
    const { rerender } = render(
      <PrivyRealProvider appId="x" onAuthChange={onAuthChange} />,
    );

    // A real auth change DOES republish — but the action callback identity
    // must remain stable so consumer effects don't churn.
    h.privy = privyValue({ authenticated: false, user: null });
    rerender(<PrivyRealProvider appId="x" onAuthChange={onAuthChange} />);

    expect(states.length).toBeGreaterThanOrEqual(2);
    expect(states[0].getAccessToken).toBe(states[states.length - 1].getAccessToken);
  });
});
