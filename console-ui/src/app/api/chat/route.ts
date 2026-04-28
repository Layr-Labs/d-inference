import { NextRequest } from "next/server";

export const runtime = "nodejs";
// Disable body parsing and response buffering for streaming
export const dynamic = "force-dynamic";

const SEALED_CT = "application/darkbloom-sealed+json";

const COORD_URL = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

export async function POST(req: NextRequest) {
  const coordUrl = COORD_URL;
  const apiKey = req.headers.get("x-api-key") || "";
  const incomingCt = req.headers.get("content-type") || "application/json";
  const isSealed = incomingCt.toLowerCase().startsWith(SEALED_CT);

  // Forward the body bytes verbatim. For plaintext we keep the existing
  // JSON-roundtrip behavior (preserves the existing tests); for sealed we
  // must not touch the bytes — JSON.parse + stringify would reformat them.
  const bodyBytes = isSealed
    ? new Uint8Array(await req.arrayBuffer())
    : (() => {
        // small allocation for plaintext path; stay byte-clean here too so
        // we don't accidentally drop fields some sender added.
        return undefined;
      })();

  const fetchInit: RequestInit = {
    method: "POST",
    headers: {
      "Content-Type": isSealed ? SEALED_CT : "application/json",
      ...(apiKey ? { Authorization: `Bearer ${apiKey}` } : {}),
    },
    body: isSealed ? bodyBytes : JSON.stringify(await req.json()),
  };

  const upstream = await fetch(`${coordUrl}/v1/chat/completions`, fetchInit);

  const respHeaders = new Headers();
  // Pass-through content type so sealed responses keep their advertised type.
  const upstreamCt = upstream.headers.get("content-type") || "";
  if (upstreamCt.startsWith("text/event-stream")) {
    respHeaders.set("Content-Type", "text/event-stream");
    respHeaders.set("Cache-Control", "no-cache, no-transform");
    respHeaders.set("Connection", "keep-alive");
    respHeaders.set("X-Accel-Buffering", "no");
  } else if (upstreamCt) {
    respHeaders.set("Content-Type", upstreamCt);
  }

  const passthroughHeaders = [
    "x-provider-attested",
    "x-provider-trust-level",
    "x-provider-secure-enclave",
    "x-provider-mda-verified",
    "x-provider-chip",
    "x-provider-serial",
    "x-provider-model",
    "x-request-id",
    "x-attestation-se-public-key",
    "x-attestation-device-serial",
    "x-eigen-sealed",
    "x-eigen-sealed-kid",
  ];
  for (const h of passthroughHeaders) {
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
