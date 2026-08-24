import { NextResponse } from "next/server";
import { EARNINGS_MARKET_TIMEOUT_MS } from "@/lib/api/earnings-market";
import { cacheControl, coordinatorUrl } from "@/lib/server/coordinator";

export async function GET() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), EARNINGS_MARKET_TIMEOUT_MS);
  try {
    const response = await fetch(`${coordinatorUrl()}/v1/earnings/market`, {
      cache: "no-store",
      signal: controller.signal,
    });
    const body = await response.text();
    return new NextResponse(body, {
      status: response.status,
      headers: {
        "Content-Type": response.headers.get("Content-Type") || "application/json",
        "Cache-Control": response.ok ? cacheControl(60, 300) : "no-store",
      },
    });
  } catch {
    return NextResponse.json(
      { error: { type: "upstream_unavailable", message: "earnings market unavailable" } },
      { status: 503, headers: { "Cache-Control": "no-store" } },
    );
  } finally {
    clearTimeout(timeout);
  }
}
