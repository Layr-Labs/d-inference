import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

type ProvidersResponse = {
  providers?: Array<{
    online?: boolean;
    status?: string;
    runtime_verified?: boolean;
    last_challenge_verified?: string;
    models?: Array<{ id?: string }>;
  }>;
};

export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const res = await fetch(`${coordinatorUrl()}/v1/me/providers`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }

  const data = (await res.json()) as ProvidersResponse;
  const ids = new Set<string>();
  for (const provider of data.providers ?? []) {
    if (
      !provider.online ||
      provider.status === "untrusted" ||
      !provider.runtime_verified ||
      !provider.last_challenge_verified
    ) {
      continue;
    }
    for (const model of provider.models ?? []) {
      if (model.id) ids.add(model.id);
    }
  }

  return NextResponse.json({ models: [...ids].sort() });
}
