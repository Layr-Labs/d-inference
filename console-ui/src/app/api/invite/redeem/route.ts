import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

export async function POST(req: NextRequest) {
  const apiKey = req.headers.get("x-api-key") || "";
  const authHeader = apiKey ? `Bearer ${apiKey}` : privyAuth(req);
  const body = await req.json();

  const res = await fetch(`${coordinatorUrl()}/v1/invite/redeem`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(authHeader ? { Authorization: authHeader } : {}),
    },
    body: JSON.stringify(body),
  });

  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    return NextResponse.json(data, { status: res.status });
  }
  return NextResponse.json(data);
}
