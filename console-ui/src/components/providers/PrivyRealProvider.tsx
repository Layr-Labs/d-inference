"use client";

import { useCallback, useEffect, useRef } from "react";
import { PrivyProvider, usePrivy } from "@privy-io/react-auth";
import type { AuthState } from "./PrivyClientProvider";

// The real Privy provider. This module statically imports @privy-io/react-auth
// (~409 KB gz) and is loaded *only* via next/dynamic from PrivyClientProvider,
// so the SDK becomes an on-demand chunk instead of riding the shared layout
// bundle on every route (perf F1). It reports the live auth state up to the
// synchronous AuthContext via onAuthChange, so children never wait on it.

function PrivyAuthBridge({ onAuthChange }: { onAuthChange: (s: AuthState) => void }) {
  const privy = usePrivy();
  const { ready, authenticated, user } = privy;

  // usePrivy() returns a NEW object on every internal tick (token refresh,
  // etc.). Closing over it directly gave getAccessToken/login/logout a fresh
  // identity each tick, which pushed a new AuthState into context and
  // invalidated every consumer effect — most visibly the key auto-provision,
  // which then stormed POST /api/auth/keys. Hold the live instance in a ref so
  // the action callbacks stay STABLE while still calling the latest Privy.
  const privyRef = useRef(privy);
  privyRef.current = privy;

  const getAccessToken = useCallback(() => privyRef.current.getAccessToken(), []);
  const login = useCallback(() => privyRef.current.login(), []);
  const logout = useCallback(() => privyRef.current.logout(), []);

  // Only publish a new AuthState when the MEANINGFUL auth state changes
  // (readiness, authentication, or which user). A token refresh that leaves
  // those untouched must not churn the context. The action callbacks above are
  // stable refs, so they are intentionally excluded from the deps.
  const userId = (user as { id?: string } | null)?.id ?? null;
  useEffect(() => {
    onAuthChange({ ready, authenticated, user, login, logout, getAccessToken });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, authenticated, userId, onAuthChange]);

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
