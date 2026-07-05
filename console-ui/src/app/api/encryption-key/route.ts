import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// Proxies GET /v1/encryption-key from the configured coordinator. Public —
// returns 503 when the coordinator hasn't enabled sender encryption (no
// mnemonic). The browser caches the result with a 1h TTL.
export async function GET(_req: NextRequest) {
  const res = await fetch(`${coordinatorUrl()}/v1/encryption-key`, { cache: "no-store" });
  if (res.status === 503) {
    return NextResponse.json(
      { error: "encryption_unavailable" },
      { status: 503 },
    );
  }
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  const body = await res.json();
  return NextResponse.json(body, {
    headers: { "Cache-Control": "public, max-age=300" },
  });
}
