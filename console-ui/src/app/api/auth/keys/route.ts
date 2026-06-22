import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "@/lib/server/coordinator";

export async function POST(req: NextRequest) {
  // Privy auth is optional here: the coordinator decides. Forward when present.
  const authHeader = privyAuth(req);

  const res = await fetch(`${coordinatorUrl()}/v1/auth/keys`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(authHeader ? { Authorization: authHeader } : {}),
    },
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
