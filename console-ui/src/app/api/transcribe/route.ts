import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const defaultCoord =
    process.env.NEXT_PUBLIC_COORDINATOR_URL ||
    "https://inference-test.openinnovation.dev";
  const coordUrl = req.headers.get("x-coordinator-url") || defaultCoord;
  const apiKey = req.headers.get("x-api-key") || "";

  const formData = await req.formData();

  const upstream = await fetch(`${coordUrl}/v1/audio/transcriptions`, {
    method: "POST",
    headers: {
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
    },
    body: formData,
  });

  if (!upstream.ok) {
    const text = await upstream.text();
    return NextResponse.json({ error: text }, { status: upstream.status });
  }

  const data = await upstream.json();
  return NextResponse.json(data);
}
