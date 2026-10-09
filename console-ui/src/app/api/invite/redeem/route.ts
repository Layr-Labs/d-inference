import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export async function POST(req: NextRequest) {
  const apiKey = req.headers.get("x-api-key") || "";
  const body = await req.json();

  const res = await fetch(`${coordinatorUrl()}/v1/invite/redeem`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
    },
    body: JSON.stringify(body),
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    return NextResponse.json(data, { status: res.status });
  }
  return NextResponse.json(data);
}
