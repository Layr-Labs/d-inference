"use client";

import { createContext, useContext, useState, useEffect, useCallback } from "react";
import { PrivyProvider, usePrivy } from "@privy-io/react-auth";

const PRIVY_APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID || "";
const IS_PRIVY_CONFIGURED = PRIVY_APP_ID && PRIVY_APP_ID !== "placeholder";

function isProductionEnv(): boolean {
  return process.env.NODE_ENV === "production";
}

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

function PrivyAuthBridge({ children }: { children: React.ReactNode }) {
  const privy = usePrivy();

  const getAccessToken = useCallback(async () => {
    return privy.getAccessToken();
  }, [privy]);

  const value: AuthState = {
    ready: privy.ready,
    authenticated: privy.authenticated,
    user: privy.user,
    login: privy.login,
    logout: privy.logout,
    getAccessToken,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

function PrivyClientProviderInner({ children }: { children: React.ReactNode }) {
  const [mounted, setMounted] = useState(false);
  useEffect(() => setMounted(true), []);

  if (!mounted) {
    return (
      <AuthContext.Provider value={SSR_AUTH}>
        {children}
      </AuthContext.Provider>
    );
  }

  return (
    <PrivyProvider
      appId={PRIVY_APP_ID}
      config={{
        loginMethods: ["email"],
        appearance: {
          theme: "dark",
          accentColor: "#6366f1",
        },
        embeddedWallets: {},
      }}
    >
      <PrivyAuthBridge>{children}</PrivyAuthBridge>
    </PrivyProvider>
  );
}

export function PrivyClientProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!IS_PRIVY_CONFIGURED) {
    if (isProductionEnv()) {
      return (
        <div className="min-h-screen bg-bg-primary flex items-center justify-center p-4">
          <div className="max-w-md w-full rounded-lg border border-red-800 bg-red-950/40 p-8 text-center">
            <h1 className="text-lg font-semibold text-red-400 mb-2">
              Authentication not configured
            </h1>
            <p className="text-sm text-red-300/80">
              Authentication is not configured (NEXT_PUBLIC_PRIVY_APP_ID
              missing). This deployment is misconfigured.
            </p>
          </div>
        </div>
      );
    }
    return (
      <AuthContext.Provider value={MOCK_AUTH}>
        {children}
      </AuthContext.Provider>
    );
  }

  return <PrivyClientProviderInner>{children}</PrivyClientProviderInner>;
}
