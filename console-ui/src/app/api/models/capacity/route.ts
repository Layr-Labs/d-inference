import { NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

export async function GET() {
  const res = await fetch(`${coordinatorUrl()}/v1/models/capacity`, { cache: "no-store" });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json(), {
    headers: { "Cache-Control": cacheControl(10, 30) },
  });
}
