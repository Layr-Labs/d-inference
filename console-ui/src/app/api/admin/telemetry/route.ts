import { NextRequest, NextResponse } from "next/server";

// Admin-only proxy for the coordinator's GET /v1/admin/telemetry.
// Passes through the user's Authorization header verbatim so the coordinator
// enforces admin checks.

const DEFAULT_COORD =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;
  const auth = req.headers.get("authorization");
  if (!auth) {
    return NextResponse.json({ error: "unauthenticated" }, { status: 401 });
  }
  const url = new URL(req.url);
  const qs = url.search;
  try {
    const upstream = await fetch(`${coordUrl}/v1/admin/telemetry${qs}`, {
      headers: { Authorization: auth },
      signal: AbortSignal.timeout(15_000),
    });
    const text = await upstream.text();
    return new NextResponse(text, {
      status: upstream.status,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "upstream failed" },
      { status: 502 },
    );
  }
}
