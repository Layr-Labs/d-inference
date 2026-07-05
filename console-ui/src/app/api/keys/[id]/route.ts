import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for a single API key: GET (inspect), PATCH (update limits / disabled),
// DELETE (revoke). Privy-only auth with the same header → cookie fallback as
// /api/keys. Next 16 dynamic route params are async.

type Ctx = { params: Promise<{ id: string }> };

export async function GET(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { id } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/keys/${encodeURIComponent(id)}`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  return passthrough(res);
}

export async function PATCH(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { id } = await params;
  const body = await req.text();
  const res = await fetch(`${coordinatorUrl()}/v1/keys/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", Authorization: authHeader },
    body: body || "{}",
  });
  return passthrough(res);
}

export async function DELETE(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { id } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/keys/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
