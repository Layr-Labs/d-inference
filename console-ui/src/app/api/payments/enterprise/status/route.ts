import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET(req: NextRequest) {
  const coordUrl = DEFAULT_COORD;
  const apiKey = req.headers.get("x-api-key") || "";

  let authHeader = req.headers.get("authorization") || "";
  if (!authHeader && apiKey) authHeader = `Bearer ${apiKey}`;
  if (!authHeader) {
    const privyToken = req.cookies.get("privy-token")?.value;
    if (privyToken) authHeader = `Bearer ${privyToken}`;
  }

  const res = await fetch(`${coordUrl}/v1/billing/enterprise/status`, {
    headers: { ...(authHeader ? { Authorization: authHeader } : {}) },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
