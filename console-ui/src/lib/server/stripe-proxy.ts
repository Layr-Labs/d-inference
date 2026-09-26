import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth } from "./coordinator";

type StripeRequest =
  | { method?: "GET"; query?: "refresh" | "limit" }
  | { method: "POST"; body?: "json" }
  | { method: "DELETE" };

/**
 * Stripe session operations leave auth enforcement to the coordinator. Their
 * browser contract wraps upstream error text, normalizes success to 200, and
 * tolerates an empty/invalid successful JSON response. Quote has a different
 * status/error contract and intentionally uses its own adapter.
 */
export async function proxyStripe(
  req: NextRequest,
  path: string,
  operation: StripeRequest = {},
) {
  const auth = privyAuth(req);
  const query = "query" in operation ? operation.query : undefined;
  const value = query ? new URL(req.url).searchParams.get(query) : null;
  const body = "body" in operation && operation.body
    ? JSON.stringify(await req.json().catch(() => ({})))
    : undefined;
  const suffix = value ? `?${query}=${value}` : "";
  const res = await fetch(`${coordinatorUrl()}${path}${suffix}`, {
    ...(operation.method ? { method: operation.method } : {}),
    headers: {
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(auth ? { Authorization: auth } : {}),
    },
    ...(body !== undefined ? { body } : {}),
  });
  if (!res.ok) {
    return NextResponse.json({ error: await res.text() }, { status: res.status });
  }
  return NextResponse.json(await res.json().catch(() => ({})));
}
