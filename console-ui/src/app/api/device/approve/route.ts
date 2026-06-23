import { NextRequest } from "next/server";
import { coordinatorUrl, privyAuth, passthrough, missingPrivyToken } from "@/lib/server/coordinator";

// Proxy for POST /v1/device/approve (RFC 8628 device-link approval). Same-origin
// so the /link page no longer posts the coordinator directly with a hardcoded
// prod URL (perf F9 / SSRF-safe URL resolution).
export async function POST(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const body = await req.text();
  const res = await fetch(`${coordinatorUrl()}/v1/device/approve`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: authHeader },
    body: body || "{}",
  });
  return passthrough(res);
}
