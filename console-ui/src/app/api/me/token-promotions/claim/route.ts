import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

export async function POST(req: NextRequest) {
  const authorization = privyAuth(req);
  if (!authorization) return missingPrivyToken();
  const response = await fetch(`${coordinatorUrl()}/v1/me/token-promotions/claim`, { method: "POST", headers: { Authorization: authorization, "Content-Type": "application/json" }, body: await req.text(), cache: "no-store" });
  return new NextResponse(await response.text(), { status: response.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}
