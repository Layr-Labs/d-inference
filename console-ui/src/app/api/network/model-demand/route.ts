import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

const WINDOWS = new Set(["24h", "7d", "30d"]);
export async function GET(req: NextRequest) {
  const window = req.nextUrl.searchParams.get("window") || "24h";
  if (!WINDOWS.has(window)) return NextResponse.json({ error: "window must be one of: 24h, 7d, 30d" }, { status: 400 });
  try {
    const response = await fetch(`${coordinatorUrl()}/v1/network/model-demand?window=${window}`, {
      cache: "no-store", signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) return NextResponse.json({ error: "Model demand unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } });
    return NextResponse.json(await response.json(), { headers: { "Cache-Control": cacheControl(60, 60) } });
  } catch {
    return NextResponse.json({ error: "Model demand unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
}
