import { NextRequest, NextResponse } from "next/server";

// Proxy for removing a single machine from the provider portal:
// DELETE /v1/me/providers/{serial}. Privy-only auth with the same header →
// cookie fallback as the other /api/me proxies. Next 16 dynamic route params
// are async. The upstream coordinator enforces ownership + the online guard;
// this route just forwards the call with the caller's Privy token.

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

type Ctx = { params: Promise<{ serial: string }> };

export async function DELETE(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const { serial } = await params;
  const res = await fetch(`${DEFAULT_COORD}/v1/me/providers/${encodeURIComponent(serial)}`, {
    method: "DELETE",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
