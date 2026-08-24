import { NextResponse } from "next/server";
import { cacheControl, coordinatorUrl } from "@/lib/server/coordinator";

export async function GET() {
  const response = await fetch(`${coordinatorUrl()}/v1/earnings/market`, {
    cache: "no-store",
  });
  const body = await response.text();
  return new NextResponse(body, {
    status: response.status,
    headers: {
      "Content-Type": response.headers.get("Content-Type") || "application/json",
      "Cache-Control": response.ok ? cacheControl(60, 300) : "no-store",
    },
  });
}
