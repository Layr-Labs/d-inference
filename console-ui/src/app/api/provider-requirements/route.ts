import { NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export async function GET() {
  try {
    const res = await fetch(`${coordinatorUrl()}/v1/provider-requirements`, {
      cache: "no-store",
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      return NextResponse.json(
        { error: `Upstream ${res.status}` },
        { status: res.status, headers: { "Cache-Control": "no-store" } }
      );
    }
    return NextResponse.json(await res.json(), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch {
    return NextResponse.json(
      { error: "Provider requirements upstream timed out" },
      { status: 504, headers: { "Cache-Control": "no-store" } }
    );
  }
}
