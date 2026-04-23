import { NextRequest, NextResponse } from "next/server";

// Proxy for POST /v1/billing/stripe/create-session. Stripe Checkout is
// Privy-only (no API-key access), so we forward the Privy session token via
// the cookie fallback when no Authorization header is present.

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function POST(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;

  let authHeader = req.headers.get("authorization") || "";
  if (!authHeader) {
    const privyToken = req.cookies.get("privy-token")?.value;
    if (privyToken) authHeader = `Bearer ${privyToken}`;
  }

  const body = await req.json().catch(() => ({}));

  const res = await fetch(`${coordUrl}/v1/billing/stripe/create-session`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(authHeader ? { Authorization: authHeader } : {}),
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
