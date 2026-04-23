import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;

  let authHeader = req.headers.get("authorization") || "";
  if (!authHeader) {
    const privyToken = req.cookies.get("privy-token")?.value;
    if (privyToken) {
      authHeader = `Bearer ${privyToken}`;
    }
  }
  if (!authHeader) {
    return NextResponse.json({ error: "missing privy token" }, { status: 401 });
  }

  const res = await fetch(`${coordUrl}/v1/me/providers`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
