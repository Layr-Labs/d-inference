import { NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export async function GET() {
  try {
    const response = await fetch(`${coordinatorUrl()}/v1/providers/attestation`, {
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
