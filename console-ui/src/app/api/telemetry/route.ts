import { NextRequest, NextResponse } from "next/server";

// Proxy route for browser telemetry events. Forwards to the coordinator's
// /v1/telemetry/events endpoint. Body size cap mirrors the coordinator's
// 64KB limit so we fail fast on accidental floods.

const DEFAULT_COORD =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";
const MAX_BODY = 64 * 1024;

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;

  // Read with explicit size cap.
  const raw = await req.text();
  if (raw.length > MAX_BODY) {
    return NextResponse.json(
      { error: "telemetry payload too large" },
      { status: 413 },
    );
  }

  // Pass through the user's auth header if present so the coordinator can
  // attribute events to the account. Anonymous browsers also work — they
  // just hit the stricter anon rate limit.
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  const auth = req.headers.get("authorization");
  if (auth) headers["Authorization"] = auth;

  try {
    const upstream = await fetch(`${coordUrl}/v1/telemetry/events`, {
      method: "POST",
      headers,
      body: raw,
      // Don't let a hung coordinator block the browser unload path.
      signal: AbortSignal.timeout(10_000),
    });
    const text = await upstream.text();
    return new NextResponse(text, {
      status: upstream.status,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return NextResponse.json(
      { error: e instanceof Error ? e.message : "telemetry forward failed" },
      { status: 502 },
    );
  }
}
