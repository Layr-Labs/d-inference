import { NextRequest } from "next/server";
import { coordinatorUrl, passthrough, privyAuth } from "@/lib/server/coordinator";

export async function PUT(req: NextRequest) {
  const authHeader = privyAuth(req);
  const body = await req.json().catch(() => ({}));
  const res = await fetch(`${coordinatorUrl()}/v1/billing/stripe/auto-withdraw`, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      ...(authHeader ? { Authorization: authHeader } : {}),
    },
    body: JSON.stringify(body),
  });
  return passthrough(res);
}
