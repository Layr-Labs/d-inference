import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

// Proxy for POST /v1/billing/stripe/create-session. Stripe Checkout is
// Privy-only (no API-key access), so we forward the Privy session token via
// the cookie fallback when no Authorization header is present.

export async function POST(req: NextRequest) {
  const authHeader = privyAuth(req);
  const body = await req.json().catch(() => ({}));

  const res = await fetch(`${coordinatorUrl()}/v1/billing/stripe/create-session`, {
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
