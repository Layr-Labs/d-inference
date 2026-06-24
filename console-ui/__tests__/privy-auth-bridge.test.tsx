import { describe, it, expect, vi, beforeEach } from "vitest";
import { render } from "@testing-library/react";

// Regression coverage for the "sidebar nav unclickable in production" bug.
//
// Root cause: `PrivyAuthBridge` consumed `usePrivy()` and pushed the auth state
// up to the app via `onAuthChange` from an effect whose dependencies included
// `login`/`logout`/`getAccessToken`. The Privy SDK hands back FRESH identities
// for those methods on most renders, so the effect re-fired and called
// `onAuthChange` (a `setState` in the parent provider) on essentially every
// render. The rendered output never changed, so it produced no DOM mutations and
// was invisible — but it perpetually re-scheduled default-priority work and
// starved React's lower-priority navigation transitions. The result: `<Link>` /
// `router.push()` silently no-opped under the Next 16 App Router, i.e. the
// sidebar nav looked fine but clicking did nothing.
//
// The fix stabilizes the exposed callbacks (refs + `useCallback([])`) and keys
// the effect on a stable `userId`, so `onAuthChange` fires only on real auth
// changes.

const { usePrivyCalls } = vi.hoisted(() => ({ usePrivyCalls: { n: 0 } }));

vi.mock("@privy-io/react-auth", () => ({
  // Passthrough provider so we can mount the bridge without the real SDK.
  PrivyProvider: ({ children }: { children: React.ReactNode }) => children,
  // Mimic the real SDK: stable auth fields, but NEW method identities each call.
  usePrivy: () => {
    usePrivyCalls.n++;
    return {
      ready: true,
      authenticated: false,
      user: null,
      login: () => {},
      logout: async () => {},
      getAccessToken: async () => "token",
    };
  },
}));

import PrivyRealProvider from "@/components/providers/PrivyRealProvider";

describe("PrivyAuthBridge stability (regression: router.push no-op / nav unclickable)", () => {
  beforeEach(() => {
    usePrivyCalls.n = 0;
  });

  it("reports auth state once despite re-renders + unstable Privy callbacks", () => {
    const onAuthChange = vi.fn();
    const { rerender } = render(
      <PrivyRealProvider appId="test-app" onAuthChange={onAuthChange} />
    );
    // Force several re-renders; the mocked SDK returns fresh login/logout/
    // getAccessToken each time, exactly like the real SDK does in production.
    for (let i = 0; i < 6; i++) {
      rerender(
        <PrivyRealProvider appId="test-app" onAuthChange={onAuthChange} />
      );
    }

    // The bridge really did re-render multiple times...
    expect(usePrivyCalls.n).toBeGreaterThan(1);
    // ...but auth state is reported ONCE, not once per render. Pre-fix this was
    // 7 (1 mount + 6 rerenders), which is what starved navigation transitions.
    expect(onAuthChange).toHaveBeenCalledTimes(1);

    const state = onAuthChange.mock.calls[0][0];
    expect(state.ready).toBe(true);
    expect(state.authenticated).toBe(false);
    expect(typeof state.getAccessToken).toBe("function");
    expect(typeof state.login).toBe("function");
    expect(typeof state.logout).toBe("function");
  });
});
