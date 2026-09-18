export type Workspace = "consumer" | "provider";

export type ProviderAccount = {
  status: "loading" | "guest" | "new" | "linked" | "error";
  total: number;
  online: number;
};

export function workspaceForPath(pathname: string): Workspace | null {
  if (pathname === "/providers" || pathname.startsWith("/providers/") || pathname === "/earn" || pathname === "/leaderboard") return "provider";
  if (["/chat", "/models", "/api-console", "/billing"].some((path) => pathname === path || pathname.startsWith(`${path}/`))) return "consumer";
  return null;
}

export function providerDestination(account: ProviderAccount) {
  return account.status === "guest" || account.status === "new" ? "/providers/setup" : "/providers";
}

export function summarizeProviders(data: unknown): ProviderAccount {
  if (!data || typeof data !== "object" || !("providers" in data) || !Array.isArray(data.providers)) throw new Error("Invalid provider response");
  if (data.providers.some((provider: unknown) => !provider || typeof provider !== "object" || !("id" in provider) || typeof provider.id !== "string")) throw new Error("Invalid provider record");
  return {
    status: data.providers.length ? "linked" : "new",
    total: data.providers.length,
    online: data.providers.filter((provider) => provider.online === true).length,
  };
}
