import { NextRequest, NextResponse } from "next/server";
import { cacheControl, coordinatorUrl } from "@/lib/server/coordinator";

export async function GET(req: NextRequest) {
  const search = req.nextUrl.searchParams.toString();
  const suffix = search ? `?${search}` : "";
  const res = await fetch(`${coordinatorUrl()}/v1/network/totals${suffix}`, {
    cache: "no-store",
  });
  if (!res.ok) {
    return NextResponse.json(
      { error: `Upstream ${res.status}` },
      { status: res.status },
    );
  }
  return NextResponse.json(await res.json(), {
    headers: { "Cache-Control": cacheControl(10, 30) },
  });
}
