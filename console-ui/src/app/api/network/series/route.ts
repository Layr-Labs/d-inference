import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

const SUPPORTED_WINDOWS = new Set(["30m", "24h", "7d", "30d"]);

export async function GET(req: NextRequest) {
  const window = req.nextUrl.searchParams.get("window") || "30m";
  if (!SUPPORTED_WINDOWS.has(window)) {
    return NextResponse.json(
      { error: "window must be one of: 30m, 24h, 7d, 30d" },
      { status: 400 },
    );
  }

  const response = await fetch(
    `${coordinatorUrl()}/v1/network/series?window=${encodeURIComponent(window)}`,
    { cache: "no-store" },
  );
  const body = await response.json().catch(() => ({ error: `Upstream ${response.status}` }));
  return NextResponse.json(body, {
    status: response.status,
    headers: { "Cache-Control": cacheControl(30, 60) },
  });
}
