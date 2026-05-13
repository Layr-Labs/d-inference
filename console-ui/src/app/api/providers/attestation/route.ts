import { NextResponse } from "next/server";

const DEFAULT_COORD =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET() {
  const res = await fetch(`${DEFAULT_COORD}/v1/providers/attestation`);
  if (!res.ok) {
    return NextResponse.json(
      { error: `Upstream ${res.status}` },
      { status: res.status }
    );
  }
  return NextResponse.json(await res.json());
}
