import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for the coordinator's API-key management endpoints. These are
// Privy-only: the browser sends `Authorization: Bearer <privy access token>`,
// and we fall back to the `privy-token` cookie (same precedence as
// /api/auth/keys). The coordinator URL is resolved server-side and never from
// client input (SSRF prevention).

export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const res = await fetch(`${coordinatorUrl()}/v1/keys`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  return passthrough(res);
}

export async function POST(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const body = await req.text();
  const res = await fetch(`${coordinatorUrl()}/v1/keys`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: authHeader },
    body: body || "{}",
  });
  return passthrough(res);
}
