import { NextRequest, NextResponse } from "next/server";

// Proxy for GET /v1/billing/stripe/status. Forwards `?refresh=1` so the
// Billing page can request a live Stripe refresh after onboarding redirect.

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;

  let authHeader = req.headers.get("authorization") || "";
  if (!authHeader) {
    const privyToken = req.cookies.get("privy-token")?.value;
    if (privyToken) authHeader = `Bearer ${privyToken}`;
  }

  const url = new URL(req.url);
  const refresh = url.searchParams.get("refresh");
  const upstream = `${coordUrl}/v1/billing/stripe/status${refresh ? `?refresh=${refresh}` : ""}`;

  const res = await fetch(upstream, {
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
