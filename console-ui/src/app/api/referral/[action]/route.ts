import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, missingPrivyToken, passthrough, privyAuth } from "@/lib/server/coordinator";

type Context = { params: Promise<{ action: string }> };

async function forward(req: NextRequest, context: Context, allowed: string[]) {
  const { action } = await context.params;
  if (!allowed.includes(action)) return NextResponse.json({ error: "Not found" }, { status: 404 });
  const authorization = privyAuth(req);
  if (!authorization) return missingPrivyToken();

  try {
    const response = await fetch(`${coordinatorUrl()}/v1/referral/${action}`, {
      method: req.method,
      headers: { Authorization: authorization, "Content-Type": "application/json" },
      ...(req.method === "POST" ? { body: await req.text() } : {}),
      cache: "no-store",
    });
    const result = await passthrough(response);
    result.headers.set("Cache-Control", "private, no-store");
    const retryAfter = response.headers.get("retry-after");
    if (retryAfter) result.headers.set("Retry-After", retryAfter);
    return result;
  } catch {
    return NextResponse.json({ error: "Referral service is temporarily unavailable" }, { status: 502 });
  }
}

export const GET = (req: NextRequest, context: Context) => forward(req, context, ["info", "stats"]);
export const POST = (req: NextRequest, context: Context) => forward(req, context, ["register", "apply"]);
