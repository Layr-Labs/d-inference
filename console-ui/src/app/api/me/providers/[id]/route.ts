import { NextRequest } from "next/server";
import { proxyAccount, type AccountResourceContext } from "@/lib/server/account-proxy";

export async function DELETE(req: NextRequest, { params }: AccountResourceContext) {
  return proxyAccount(req, async () => `/v1/me/providers/${encodeURIComponent((await params).id)}`, { method: "DELETE" });
}
