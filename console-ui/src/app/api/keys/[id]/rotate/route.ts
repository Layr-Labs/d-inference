import { NextRequest } from "next/server";
import { proxyAccount, type AccountResourceContext } from "@/lib/server/account-proxy";

export async function POST(req: NextRequest, { params }: AccountResourceContext) {
  return proxyAccount(req, async () => `/v1/keys/${encodeURIComponent((await params).id)}/rotate`, { method: "POST" });
}
