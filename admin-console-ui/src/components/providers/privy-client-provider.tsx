"use client";

import { PrivyProvider, usePrivy } from "@privy-io/react-auth";
import { createContext, useCallback, useContext } from "react";

const PRIVY_APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID || "";
const IS_PRIVY_CONFIGURED = PRIVY_APP_ID !== "" && PRIVY_APP_ID !== "placeholder";

export type AdminPrivyAuth = {
  configured: boolean;
  ready: boolean;
  authenticated: boolean;
  user: unknown;
  login: () => void;
  logout: () => Promise<void>;
  getAccessToken: () => Promise<string | null>;
};

const noop = () => {};
const noopAsync = async () => {};
const noopToken = async () => null as string | null;

const UNCONFIGURED_AUTH: AdminPrivyAuth = {
  configured: false,
  ready: true,
  authenticated: false,
  user: null,
  login: noop,
  logout: noopAsync,
  getAccessToken: noopToken,
};

const AdminPrivyAuthContext = createContext<AdminPrivyAuth>(UNCONFIGURED_AUTH);

export function useAdminPrivyAuth() {
  return useContext(AdminPrivyAuthContext);
}

function PrivyAuthBridge({ children }: { children: React.ReactNode }) {
  const privy = usePrivy();

  const getAccessToken = useCallback(async () => {
    return privy.getAccessToken();
  }, [privy]);

  const value: AdminPrivyAuth = {
    configured: true,
    ready: privy.ready,
    authenticated: privy.authenticated,
    user: privy.user,
    login: privy.login,
    logout: privy.logout,
    getAccessToken,
  };

  return <AdminPrivyAuthContext.Provider value={value}>{children}</AdminPrivyAuthContext.Provider>;
}

function PrivyClientProviderInner({ children }: { children: React.ReactNode }) {
  return (
    <PrivyProvider
      appId={PRIVY_APP_ID}
      config={{
        loginMethods: ["email"],
        appearance: {
          theme: "dark",
          accentColor: "#1A0C6D",
        },
        embeddedWallets: {},
      }}
    >
      <PrivyAuthBridge>{children}</PrivyAuthBridge>
    </PrivyProvider>
  );
}

export function AdminPrivyClientProvider({ children }: { children: React.ReactNode }) {
  if (!IS_PRIVY_CONFIGURED) {
    return <AdminPrivyAuthContext.Provider value={UNCONFIGURED_AUTH}>{children}</AdminPrivyAuthContext.Provider>;
  }

  return <PrivyClientProviderInner>{children}</PrivyClientProviderInner>;
}
