import type { NextRequest } from "next/server";
import { coordinatorUrl } from "./coordinator";

const PRIVATE_TIER = "private-v2-process-bound";
const PREFLIGHT_BODY_LIMIT = 64 * 1024;
const PRIVATE_REQUEST_BODY_LIMIT = 24 * 1024 * 1024;
const PREFLIGHT_RESPONSE_LIMIT = 512 * 1024;

function localError(status: number, error: string): Response {
  return Response.json(
    { error },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "X-Darkbloom-Privacy-Tier": PRIVATE_TIER,
      },
    },
  );
}

async function readBoundedReader(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  limit: number,
  cancelReason: string,
): Promise<Uint8Array | null> {
  let body = new Uint8Array(Math.min(limit, 64 * 1024));
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    const nextTotal = total + value.length;
    if (nextTotal > limit) {
      await reader.cancel(cancelReason);
      return null;
    }
    if (nextTotal > body.length) {
      const capacity = Math.min(limit, Math.max(nextTotal, body.length * 2));
      const expanded = new Uint8Array(capacity);
      expanded.set(body.subarray(0, total));
      body = expanded;
    }
    body.set(value, total);
    total = nextTotal;
  }
  return body.slice(0, total);
}

async function readBoundedBody(req: NextRequest, limit: number): Promise<Uint8Array | null> {
  const declared = req.headers.get("content-length");
  if (declared !== null) {
    const length = Number(declared);
    if (!Number.isSafeInteger(length) || length < 0 || length > limit) return null;
  }
  const reader = req.body?.getReader();
  if (!reader) return new Uint8Array();
  return readBoundedReader(reader, limit, "private-v2 request body limit exceeded");
}


function responseHeaders(upstream: Response): Headers {
  const headers = new Headers();
  const contentType = upstream.headers.get("content-type") || "application/json";
  headers.set("Content-Type", contentType);
  headers.set("X-Darkbloom-Privacy-Tier", PRIVATE_TIER);
  headers.set("Cache-Control", "no-store");
  if (contentType.startsWith("text/event-stream")) {
    headers.set("Cache-Control", "no-cache, no-transform");
    headers.set("Connection", "keep-alive");
    headers.set("X-Accel-Buffering", "no");
  }
  for (const name of [
    "x-provider-attested",
    "x-provider-trust-level",
    "x-provider-secure-enclave",
    "x-provider-mda-verified",
    "x-provider-chip",
    "x-provider-model",
    "x-request-id",
    "x-attestation-se-public-key",
  ]) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

/**
 * Relays private-v2 bytes without JSON decoding, logging, or retaining a copy.
 * The stream's pull/cancel methods preserve upstream backpressure and aborts.
 */
export async function proxyPrivateV2Post(req: NextRequest, path: string): Promise<Response> {
  const apiKey = req.headers.get("x-api-key") || "";
  const authorization = req.headers.get("authorization") || (apiKey ? `Bearer ${apiKey}` : "");
  if (!authorization) return localError(401, "missing API authorization");
  const contentType = req.headers.get("content-type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return localError(415, "private-v2 requests require application/json");
  }
  const route = req.headers.get("x-darkbloom-route") || "";
  const limit = path === "/v1/private/preflight"
    ? PREFLIGHT_BODY_LIMIT
    : PRIVATE_REQUEST_BODY_LIMIT;
  const body = await readBoundedBody(req, limit);
  if (!body) return localError(413, "private-v2 request body too large");
  const upstream = await fetch(`${coordinatorUrl()}${path}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: authorization,
      ...(route ? { "X-Darkbloom-Route": route } : {}),
    },
    body,
    signal: req.signal,
    cache: "no-store",
  });
  const headers = responseHeaders(upstream);
  const reader = upstream.body?.getReader();
  if (!reader) return new Response(null, { status: upstream.status, headers });
  if (path === "/v1/private/preflight") {
    const bounded = await readBoundedReader(
      reader,
      PREFLIGHT_RESPONSE_LIMIT,
      "private-v2 preflight response limit exceeded",
    );
    if (!bounded) return localError(502, "private-v2 preflight response too large");
    return new Response(bounded, { status: upstream.status, headers });
  }

  const stream = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        controller.close();
        return;
      }
      controller.enqueue(value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });
  return new Response(stream, { status: upstream.status, headers });
}
