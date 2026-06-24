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

  // Keep a live ref to the Privy handle so the methods we expose are STABLE
  // identities. Without this, `usePrivy()` hands back fresh `login`/`logout`/
  // `getAccessToken` references on most renders, which made the effect below
  // re-fire and call `onAuthChange` on every render — a setState-in-the-parent
  // loop. It produced no DOM changes (the rendered output was identical), so it
  // was invisible, but it perpetually re-scheduled default-priority work and
  // starved React's lower-priority navigation transitions, so `<Link>` /
  // `router.push` silently no-opped (the App Router sidebar became unclickable).
  const privyRef = useRef(privy);
  privyRef.current = privy;

  const getAccessToken = useCallback(() => privyRef.current.getAccessToken(), []);
  const login = useCallback(() => privyRef.current.login(), []);
  const logout = useCallback(() => privyRef.current.logout(), []);

  // Identify the user by a stable primitive so an unstable `user` object
  // identity from Privy doesn't re-fire this effect every render.
  const userId = (user as { id?: string } | null)?.id ?? null;

  useEffect(() => {
    onAuthChange({
      ready,
      authenticated,
      user: privyRef.current.user,
      login,
      logout,
      getAccessToken,
    });
    // Depend only on the values that meaningfully change auth state; the
    // callbacks are stable (refs) so this fires once per real auth change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, authenticated, userId, login, logout, getAccessToken, onAuthChange]);

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
