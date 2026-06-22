import { NextRequest, NextResponse } from "next/server";

// Server-side coordinator helpers for the /api/* proxy routes.
//
// The coordinator base URL is resolved here, ONCE, from the environment — never
// from client input (SSRF prevention). Before this module the
// `process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev"`
// fallback was copy-pasted into ~27 route files under three different names
// (proposal F6).

const DEFAULT_COORDINATOR_URL = "https://api.darkbloom.dev";

/** The configured coordinator base URL (env, with a prod default). */
export function coordinatorUrl(): string {
  return process.env.NEXT_PUBLIC_COORDINATOR_URL || DEFAULT_COORDINATOR_URL;
}

/**
 * Resolve the Privy auth header for a request: the incoming Authorization
 * header, falling back to the `privy-token` cookie. Returns "" when neither is
 * present so callers can short-circuit with a 401.
 */
export function privyAuth(req: NextRequest): string {
  const header = req.headers.get("authorization") || "";
  if (header) return header;
  const cookie = req.cookies.get("privy-token")?.value;
  return cookie ? `Bearer ${cookie}` : "";
}

/**
 * Forward an upstream response verbatim — status code, content-type, and body
 * bytes — so the coordinator's contract (structured errors, once-only secrets)
 * reaches the client unchanged.
 */
export async function passthrough(res: Response): Promise<NextResponse> {
  const text = await res.text();
  return new NextResponse(text, {
    status: res.status,
    headers: { "Content-Type": res.headers.get("content-type") || "application/json" },
  });
}

/** Standard "missing privy token" 401 used by Privy-only routes. */
export function missingPrivyToken(): NextResponse {
  return NextResponse.json({ error: "missing privy token" }, { status: 401 });
}
