import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";

// Retain the route for old browser bundles, but reject before reading or
// forwarding the body. Arbitrary messages/stacks are not a privacy-safe schema.
export async function POST(_req: NextRequest) {
  return NextResponse.json(
    {
      error: {
        code: "telemetry_ingest_disabled",
        message: "client telemetry ingestion is disabled",
      },
    },
    { status: 410 },
  );
}
