import { NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

export async function GET() {
  const res = await fetch(`${coordinatorUrl()}/v1/pricing`);
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  // Prices change rarely — let the edge serve repeats for minutes (perf F5a).
  return NextResponse.json(await res.json(), {
    headers: { "Cache-Control": cacheControl(300, 600) },
  });
}
