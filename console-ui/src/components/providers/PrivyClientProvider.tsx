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

const MOCK_AUTH: AuthState = {
  ready: true,
  authenticated: true,
  user: null,
  login: noop,
  logout: noopAsync,
  getAccessToken: noopToken,
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
