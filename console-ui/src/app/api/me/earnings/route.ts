import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for GET /v1/provider/account-earnings. Lets the provider-earnings page
// call same-origin (no cross-origin preflight, coordinator URL resolved
// server-side) instead of fetching the coordinator directly (perf F9).
export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const limit = req.nextUrl.searchParams.get("limit") || "100";
  const res = await fetch(
    `${coordinatorUrl()}/v1/provider/account-earnings?limit=${encodeURIComponent(limit)}`,
    { headers: { Authorization: authHeader }, cache: "no-store" },
  );
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
