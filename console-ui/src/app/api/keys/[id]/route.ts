import { NextRequest } from "next/server";
import { proxyAccount, type AccountResourceContext } from "@/lib/server/account-proxy";

export async function GET(req: NextRequest, { params }: AccountResourceContext) {
  return proxyAccount(req, async () => `/v1/keys/${encodeURIComponent((await params).id)}`);
}

export async function PATCH(req: NextRequest, { params }: AccountResourceContext) {
  return proxyAccount(req, async () => `/v1/keys/${encodeURIComponent((await params).id)}`, { method: "PATCH", body: "text" });
}

export async function DELETE(req: NextRequest, { params }: AccountResourceContext) {
  return proxyAccount(req, async () => `/v1/keys/${encodeURIComponent((await params).id)}`, { method: "DELETE" });
}
