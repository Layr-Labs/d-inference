import { NextRequest, NextResponse } from "next/server";

// Proxy for the coordinator's API-key management endpoints. These are
// Privy-only: the browser sends `Authorization: Bearer <privy access token>`,
// and we fall back to the `privy-token` cookie (same precedence as
// /api/auth/keys). The coordinator URL is resolved server-side and never from
// client input (SSRF prevention).

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";
const MISSING_AUTH = { error: "missing privy token" };

function privyAuth(req: NextRequest): string {
  const header = req.headers.get("authorization") || "";
  if (header) return header;
  const cookie = req.cookies.get("privy-token")?.value;
  return cookie ? `Bearer ${cookie}` : "";
}

// Forward the upstream response verbatim — status code and JSON body — so the
// coordinator's key-management contract (including structured error payloads
// and the once-only secret) reaches the client unchanged.
async function passthrough(res: Response): Promise<NextResponse> {
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "Content-Type": res.headers.get("content-type") || "application/json" },
  });
}

export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const res = await fetch(`${DEFAULT_COORD}/v1/keys`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  return passthrough(res);
}

export async function POST(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const body = await req.text();
  const res = await fetch(`${DEFAULT_COORD}/v1/keys`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: authHeader },
    body: body || "{}",
  });
  return passthrough(res);
}
