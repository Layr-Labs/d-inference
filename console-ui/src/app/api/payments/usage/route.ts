import { NextRequest, NextResponse } from "next/server";

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://inference-test.openinnovation.dev";

export async function GET(req: NextRequest) {
  const coordUrl = req.headers.get("x-coordinator-url") || DEFAULT_COORD;
  const apiKey = req.headers.get("x-api-key") || "";

  const res = await fetch(`${coordUrl}/v1/payments/usage`, {
    headers: { ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}) },
  });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
