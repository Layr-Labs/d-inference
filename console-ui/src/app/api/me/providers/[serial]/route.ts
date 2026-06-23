import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for removing a single machine from the provider portal:
// DELETE /v1/me/providers/{serial}. Privy-only auth with the same header →
// cookie fallback as the other /api/me proxies. Next 16 dynamic route params
// are async. The upstream coordinator enforces ownership + the online guard;
// this route just forwards the call with the caller's Privy token.

type Ctx = { params: Promise<{ serial: string }> };

export async function DELETE(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { serial } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/me/providers/${encodeURIComponent(serial)}`, {
    method: "DELETE",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
