import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for removing one machine by its opaque provider session id. Next 16
// dynamic route params are async; the coordinator enforces ownership and the
// online-machine guard.
type Ctx = { params: Promise<{ id: string }> };

export async function DELETE(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const { id } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/me/providers/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
