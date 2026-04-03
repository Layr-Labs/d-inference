import { NextRequest } from "next/server";

export const runtime = "nodejs";

export async function POST(req: NextRequest) {
  const defaultCoord = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://inference-test.openinnovation.dev";
  const coordUrl = req.headers.get("x-coordinator-url") || defaultCoord;
  const apiKey = req.headers.get("x-api-key") || "";

  const body = await req.json();

  const upstream = await fetch(`${coordUrl}/v1/images/generations`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
    },
    body: JSON.stringify(body),
  });

  const text = await upstream.text();
  return new Response(text, {
    status: upstream.status,
    headers: { "Content-Type": "application/json" },
  });
}
