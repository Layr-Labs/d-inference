"use client";

import { createContext, useContext, useState } from "react";
import dynamic from "next/dynamic";

const PRIVY_APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID || "";
const IS_PRIVY_CONFIGURED = PRIVY_APP_ID && PRIVY_APP_ID !== "placeholder";

export interface AuthState {
  ready: boolean;
  authenticated: boolean;
  user: unknown;
  login: () => void;
  logout: () => Promise<void>;
  getAccessToken: () => Promise<string | null>;
}

const noop = () => {};
const noopAsync = async () => {};
const noopToken = async () => null as string | null;

// E2E hook (Playwright only): when NEXT_PUBLIC_E2E_AUTH=1, the mock-auth path
// returns a usable token + user so authenticated flows can be driven against
// route-mocked APIs. This env var is set ONLY by the Playwright build and is
// unset in every real build, so production behaviour is unchanged.
const E2E_AUTH = process.env.NEXT_PUBLIC_E2E_AUTH === "1";

// Intentionally NOT token-shaped: a coordinator would reject it instantly, and
// if a build ever leaks NEXT_PUBLIC_E2E_AUTH the value is obviously a test
// artifact in any logs/analytics rather than a plausible bearer token. The
// inert default (no flag => user:null, getAccessToken()=>null) is the
// production-relevant invariant and is pinned by PrivyClientProvider.test.tsx so
// a future edit can't silently make the flagless build emit a usable session.
const E2E_MOCK_TOKEN = "e2e-mock-token-not-for-prod";

const MOCK_AUTH: AuthState = {
  ready: true,
  authenticated: true,
  user: E2E_AUTH ? { id: "e2e-user", email: { address: "e2e@darkbloom.test" } } : null,
  login: noop,
  logout: noopAsync,
  getAccessToken: E2E_AUTH ? async () => E2E_MOCK_TOKEN : noopToken,
};

// Pre-hydration / pre-Privy state: render immediately as "not ready yet" and
// reconcile when the lazy Privy chunk loads (progressive enhancement — perf F2).
const SSR_AUTH: AuthState = {
  ready: false,
  authenticated: false,
  user: null,
  login: noop,
  logout: noopAsync,
  getAccessToken: noopToken,
};

const AuthContext = createContext<AuthState>(MOCK_AUTH);

export function useAuthContext() {
  return useContext(AuthContext);
}

// The Privy SDK is loaded as its own on-demand chunk after first paint (perf
// F1). ssr:false keeps it out of the server render; children below render
// synchronously against AuthContext regardless of whether Privy has loaded.
const PrivyRealProvider = dynamic(() => import("./PrivyRealProvider"), {
  ssr: false,
});

function PrivyGate({ children }: { children: React.ReactNode }) {
  const [authState, setAuthState] = useState<AuthState>(SSR_AUTH);
  return (
    <AuthContext.Provider value={authState}>
      <PrivyRealProvider appId={PRIVY_APP_ID} onAuthChange={setAuthState} />
      {children}
    </AuthContext.Provider>
  );
}

export function PrivyClientProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!IS_PRIVY_CONFIGURED) {
    return (
      <AuthContext.Provider value={MOCK_AUTH}>
        {children}
      </AuthContext.Provider>
    );
  }

  return <PrivyGate>{children}</PrivyGate>;
}
