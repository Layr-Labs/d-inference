import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for POST /v1/keys/{id}/rotate. Returns a fresh secret exactly once
// (same shape as create). Privy-only auth with the standard header → cookie
// fallback. Next 16 dynamic route params are async.

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { id } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/keys/${encodeURIComponent(id)}/rotate`, {
    method: "POST",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
