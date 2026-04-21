import { NextResponse } from "next/server";

const COORD_URL = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET() {
  const coordUrl = COORD_URL;

  const res = await fetch(`${coordUrl}/health`);
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
