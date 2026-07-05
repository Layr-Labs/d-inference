import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

// Proxy for GET /v1/billing/stripe/withdrawals — recent payout history for
// the Billing page.

export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);

  const url = new URL(req.url);
  const limit = url.searchParams.get("limit");
  const upstream = `${coordinatorUrl()}/v1/billing/stripe/withdrawals${limit ? `?limit=${limit}` : ""}`;

  const res = await fetch(upstream, {
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
