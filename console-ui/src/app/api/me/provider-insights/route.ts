import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

export async function GET(req: NextRequest) {
  const auth = privyAuth(req);
  if (!auth) return missingPrivyToken();
  const window = req.nextUrl.searchParams.get("window") || "7d";
  if (window !== "7d" && window !== "30d") {
    return NextResponse.json({ error: "window must be 7d or 30d" }, { status: 400 });
  }
  try {
    const res = await fetch(`${coordinatorUrl()}/v1/me/provider-insights?window=${window}`, {
      headers: { Authorization: auth }, cache: "no-store", signal: AbortSignal.timeout(15_000),
    });
    return new NextResponse(await res.text(), {
      status: res.status,
      headers: { "Content-Type": "application/json", "Cache-Control": "private, no-store" },
    });
  } catch {
    return NextResponse.json({ error: "Provider insights unavailable" }, { status: 503 });
  }
}
