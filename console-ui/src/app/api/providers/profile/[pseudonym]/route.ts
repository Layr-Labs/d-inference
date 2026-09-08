import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ pseudonym: string }> },
) {
  const { pseudonym } = await params;
  const res = await fetch(`${coordinatorUrl()}/v1/providers/${encodeURIComponent(pseudonym)}`, {
    cache: "no-store",
  });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json(), {
    headers: { "Cache-Control": cacheControl(15, 30) },
  });
}
