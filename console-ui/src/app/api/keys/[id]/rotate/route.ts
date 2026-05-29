import { NextRequest, NextResponse } from "next/server";

// Proxy for POST /v1/keys/{id}/rotate. Returns a fresh secret exactly once
// (same shape as create). Privy-only auth with the standard header → cookie
// fallback. Next 16 dynamic route params are async.

const DEFAULT_COORD = process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";
const MISSING_AUTH = { error: "missing privy token" };

function privyAuth(req: NextRequest): string {
  const header = req.headers.get("authorization") || "";
  if (header) return header;
  const cookie = req.cookies.get("privy-token")?.value;
  return cookie ? `Bearer ${cookie}` : "";
}

async function passthrough(res: Response): Promise<NextResponse> {
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "Content-Type": res.headers.get("content-type") || "application/json" },
  });
}

export async function POST(req: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const { id } = await params;
  const res = await fetch(`${DEFAULT_COORD}/v1/keys/${encodeURIComponent(id)}/rotate`, {
    method: "POST",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
