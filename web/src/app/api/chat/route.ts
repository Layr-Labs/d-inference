import { NextRequest } from "next/server";

export const runtime = "nodejs";
// Disable body parsing and response buffering for streaming
export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  const defaultCoord = process.env.NEXT_PUBLIC_COORDINATOR_URL || "http://localhost:8080";
  const coordUrl = req.headers.get("x-coordinator-url") || defaultCoord;
  const apiKey = req.headers.get("x-api-key") || "";

  const body = await req.json();

  const upstream = await fetch(`${coordUrl}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
    },
    body: JSON.stringify(body),
  });

  const respHeaders = new Headers();
  respHeaders.set("Content-Type", "text/event-stream");
  respHeaders.set("Cache-Control", "no-cache, no-transform");
  respHeaders.set("Connection", "keep-alive");
  respHeaders.set("X-Accel-Buffering", "no");

  for (const h of ["x-provider-attested", "x-provider-trust-level", "x-provider-secure-enclave", "x-provider-mda-verified", "x-request-id"]) {
    const v = upstream.headers.get(h);
    if (v) respHeaders.set(h, v);
  }

  if (!upstream.ok) {
    const text = await upstream.text();
    return new Response(text, { status: upstream.status, headers: respHeaders });
  }

  // Manually pipe chunks to ensure no buffering
  const reader = upstream.body?.getReader();
  if (!reader) {
    return new Response("No upstream body", { status: 502 });
  }

  const stream = new ReadableStream({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        controller.close();
        return;
      }
      controller.enqueue(value);
    },
    cancel() {
      reader.cancel();
    },
  });

  return new Response(stream, { status: 200, headers: respHeaders });
}
