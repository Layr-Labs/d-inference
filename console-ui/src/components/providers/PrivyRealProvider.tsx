"use client";

import { useCallback, useEffect } from "react";
import { PrivyProvider, usePrivy } from "@privy-io/react-auth";
import type { AuthState } from "./PrivyClientProvider";

// The real Privy provider. This module statically imports @privy-io/react-auth
// (~409 KB gz) and is loaded *only* via next/dynamic from PrivyClientProvider,
// so the SDK becomes an on-demand chunk instead of riding the shared layout
// bundle on every route (perf F1). It reports the live auth state up to the
// synchronous AuthContext via onAuthChange, so children never wait on it.

function PrivyAuthBridge({ onAuthChange }: { onAuthChange: (s: AuthState) => void }) {
  const privy = usePrivy();
  const { ready, authenticated, user, login, logout } = privy;

  const getAccessToken = useCallback(() => privy.getAccessToken(), [privy]);

  useEffect(() => {
    onAuthChange({ ready, authenticated, user, login, logout, getAccessToken });
  }, [ready, authenticated, user, login, logout, getAccessToken, onAuthChange]);

  return null;
}

export default function PrivyRealProvider({
  appId,
  onAuthChange,
}: {
  appId: string;
  onAuthChange: (s: AuthState) => void;
}) {
  return (
    <PrivyProvider
      appId={appId}
      config={{
        loginMethods: ["email"],
        appearance: {
          theme: "dark",
          accentColor: "#6366f1",
        },
        // Don't auto-create embedded web3 wallets — nothing in the console uses
        // them, and it avoids pulling the @solana/viem code paths (perf F1b).
        embeddedWallets: { createOnLogin: "off" },
      }}
    >
      <PrivyAuthBridge onAuthChange={onAuthChange} />
    </PrivyProvider>
  );
}
