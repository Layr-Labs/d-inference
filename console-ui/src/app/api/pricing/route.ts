import { NextResponse } from "next/server";
import { coordinatorUrl } from "@/lib/server/coordinator";

export async function GET() {
  const res = await fetch(`${coordinatorUrl()}/v1/pricing`);
  if (!res.ok) {
    return NextResponse.json({ error: `Upstream ${res.status}` }, { status: res.status });
  }
  return NextResponse.json(await res.json());
}
