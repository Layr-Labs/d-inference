import { NextRequest, NextResponse } from "next/server";

// Proxy for a single API key: GET (inspect), PATCH (update limits / disabled),
// DELETE (revoke). Privy-only auth with the same header → cookie fallback as
// /api/keys. Next 16 dynamic route params are async.

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

type Ctx = { params: Promise<{ id: string }> };

export async function GET(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const { id } = await params;
  const res = await fetch(`${DEFAULT_COORD}/v1/keys/${encodeURIComponent(id)}`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  return passthrough(res);
}

export async function PATCH(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const { id } = await params;
  const body = await req.text();
  const res = await fetch(`${DEFAULT_COORD}/v1/keys/${encodeURIComponent(id)}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", Authorization: authHeader },
    body: body || "{}",
  });
  return passthrough(res);
}

export async function DELETE(req: NextRequest, { params }: Ctx) {
  const authHeader = privyAuth(req);
  if (!authHeader) return NextResponse.json(MISSING_AUTH, { status: 401 });

  const { id } = await params;
  const res = await fetch(`${DEFAULT_COORD}/v1/keys/${encodeURIComponent(id)}`, {
    method: "DELETE",
    headers: { Authorization: authHeader },
  });
  return passthrough(res);
}
