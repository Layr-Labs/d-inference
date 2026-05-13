import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET(req: NextRequest) {
  let authHeader = req.headers.get("authorization") || "";
  if (!authHeader) {
    const privyToken = req.cookies.get("privy-token")?.value;
    if (privyToken) {
      authHeader = `Bearer ${privyToken}`;
    }
  }
  if (!authHeader) {
    return NextResponse.json({ error: "missing auth token" }, { status: 401 });
  }

  const limit = req.nextUrl.searchParams.get("limit") || "100";
  const upstream = new URL(`${DEFAULT_COORD}/v1/provider/account-earnings`);
  upstream.searchParams.set("limit", limit);

  const res = await fetch(upstream, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
