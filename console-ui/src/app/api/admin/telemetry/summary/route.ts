import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export const runtime = "nodejs";

export async function GET(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;
  const auth = req.headers.get("authorization");
  if (!auth) {
    return NextResponse.json({ error: "unauthenticated" }, { status: 401 });
  }
  const qs = new URL(req.url).search;
  try {
    const upstream = await fetch(`${coordUrl}/v1/admin/telemetry/summary${qs}`, {
      headers: { Authorization: auth },
      signal: AbortSignal.timeout(10_000),
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
