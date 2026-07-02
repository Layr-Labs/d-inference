import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

// Proxy for DELETE /v1/billing/stripe/account — unlinks the user's Stripe
// Connect account so they can onboard a fresh one (escape hatch for accounts
// closed on Stripe's side, stuck onboarding, or wrong country/agreement).

export async function DELETE(req: NextRequest) {
  const authHeader = privyAuth(req);

  const res = await fetch(`${coordinatorUrl()}/v1/billing/stripe/account`, {
    method: "DELETE",
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
