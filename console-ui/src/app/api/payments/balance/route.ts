import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

export async function GET(req: NextRequest) {
  const apiKey = req.headers.get("x-api-key") || "";
  const authHeader = apiKey ? `Bearer ${apiKey}` : privyAuth(req);

  const res = await fetch(`${coordinatorUrl()}/v1/payments/balance`, {
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
