import { NextResponse } from "next/server";

const COORD_URL =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function GET() {
  try {
    const response = await fetch(`${COORD_URL}/v1/providers/attestation`, {
      cache: "no-store",
    });
    const data = await response.json();

    if (!response.ok) {
      return NextResponse.json(
        { error: data?.error || `Upstream ${response.status}` },
        { status: response.status },
      );
    }

    return NextResponse.json(data);
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Failed to load attestation",
      },
      { status: 500 },
    );
  }
}
