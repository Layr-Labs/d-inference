import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export async function GET(req: NextRequest) {
  const apiKey = req.headers.get("x-api-key") || "";

  const res = await fetch(`${coordinatorUrl()}/v1/payments/balance`, {
    headers: { ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}) },
  });
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
