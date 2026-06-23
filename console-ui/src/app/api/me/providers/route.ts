import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const res = await fetch(`${coordinatorUrl()}/v1/me/providers`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
