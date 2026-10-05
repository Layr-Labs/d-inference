import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, missingPrivyToken, privyAuth } from "@/lib/server/coordinator";

async function proxy(req: NextRequest, method: "GET" | "POST") {
  const auth = privyAuth(req);
  if (!auth) return missingPrivyToken();
  const response = await fetch(`${coordinatorUrl()}/v1/interest/small-models`, {
    method,
    headers: { Authorization: auth, ...(method === "POST" ? { "Content-Type": "application/json" } : {}) },
    ...(method === "POST" ? { body: await req.text() } : {}),
    cache: "no-store",
    signal: req.signal,
  });
  // Fetch/NextResponse forbid a body, including an empty string, for204.
  return new NextResponse(response.status === 204 ? null : await response.text(), {
    status: response.status,
    headers: {
      "Content-Type": response.headers.get("content-type") || "application/json",
      "Cache-Control": "private, no-store",
      ...(response.headers.has("retry-after") ? { "Retry-After": response.headers.get("retry-after")! } : {}),
    },
  });
}

export const GET = (req: NextRequest) => proxy(req, "GET");
export const POST = (req: NextRequest) => proxy(req, "POST");
