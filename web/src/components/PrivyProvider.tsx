"use client";

import { PrivyProvider as PrivyProviderBase } from "@privy-io/react-auth";

const PRIVY_APP_ID = process.env.NEXT_PUBLIC_PRIVY_APP_ID || "";

export function PrivyClientProvider({
  children,
}: {
  children: React.ReactNode;
}) {
  if (!PRIVY_APP_ID) {
    return <>{children}</>;
  }

  return (
    <PrivyProviderBase
      appId={PRIVY_APP_ID}
      config={{
        loginMethods: ["email", "google", "github"],
        appearance: {
          theme: "light",
          accentColor: "#6366f1",
        },
        embeddedWallets: {
          solana: { createOnLogin: "all-users" },
        },
      }}
    >
      {children}
    </PrivyProviderBase>
  );
}
