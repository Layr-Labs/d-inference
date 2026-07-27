import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

// Proxy for POST /v1/billing/stripe/dashboard — mints a single-use Stripe
// Express Dashboard login link so the user can change the bank account or
// debit card their payouts land in. Privy-only upstream: the link is a bearer
// credential for a session that can redirect the user's earnings.

export async function POST(req: NextRequest) {
  const authHeader = privyAuth(req);

  const res = await fetch(`${coordinatorUrl()}/v1/billing/stripe/dashboard`, {
    method: "POST",
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
