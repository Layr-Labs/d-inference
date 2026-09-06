import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

export async function POST(req: NextRequest) {
  const auth = privyAuth(req);
  const body = await req.json().catch(() => ({}));
  const response = await fetch(`${coordinatorUrl()}/v1/billing/stripe/quote`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(auth ? { Authorization: auth } : {}) },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  return NextResponse.json(await response.json().catch(() => ({ error: "Unable to review withdrawal" })), { status: response.status });
}
