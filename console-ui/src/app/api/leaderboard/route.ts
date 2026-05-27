import { NextRequest, NextResponse } from "next/server";

const COORD_URL = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET(req: NextRequest) {
  const search = req.nextUrl.searchParams.toString();
  const suffix = search ? `?${search}` : "";
  const res = await fetch(`${COORD_URL}/v1/leaderboard${suffix}`, { cache: "no-store" });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
