import { NextRequest } from "next/server";
import { coordinatorUrl, missingPrivyToken, passthrough, privyAuth } from "./coordinator";

type AccountRequest = {
  method?: "GET" | "POST" | "PATCH" | "DELETE";
  body?: "text";
};

/**
 * Privy-only account operations preserve upstream status, content type and
 * response text (including once-only secrets). Authenticate before resolving
 * dynamic IDs or reading bodies; read operations always bypass fetch caching.
 */
export async function proxyAccount(
  req: NextRequest,
  path: string | (() => Promise<string>),
  { method = "GET", body }: AccountRequest = {},
) {
  const auth = privyAuth(req);
  if (!auth) return missingPrivyToken();

  const upstreamPath = typeof path === "string" ? path : await path();
  const res = await fetch(`${coordinatorUrl()}${upstreamPath}`, {
    ...(method !== "GET" ? { method } : {}),
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      Authorization: auth,
    },
    ...(body ? { body: (await req.text()) || "{}" } : {}),
    ...(method === "GET" ? { cache: "no-store" } : {}),
  });
  return passthrough(res);
}

export type AccountResourceContext = { params: Promise<{ id: string }> };
