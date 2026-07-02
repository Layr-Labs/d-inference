import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

type ProvidersResponse = {
  challenge_max_age_seconds?: number;
  providers?: Array<{
    online?: boolean;
    status?: string;
    runtime_verified?: boolean;
    last_challenge_verified?: string;
    models?: Array<{ id?: string }>;
  }>;
};

// Fallback when the coordinator omits challenge_max_age_seconds; matches the
// providers dashboard default (warnings.ts / routing.ts).
const DEFAULT_CHALLENGE_MAX_AGE_SECONDS = 360;

// challengeFresh mirrors the coordinator's self-route freshness gate: the last
// verified attestation challenge must be within challenge_max_age_seconds. A
// merely-present timestamp is not enough — a stale-challenge machine is
// excluded from /v1/models and routing, so offering its models here would let
// the user save an allow-list the key can never use.
function challengeFresh(lastVerified: string, maxAgeSeconds: number): boolean {
  const ageSec = (Date.now() - new Date(lastVerified).getTime()) / 1000;
  return Number.isFinite(ageSec) && ageSec <= maxAgeSeconds;
}

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
  const maxAgeSeconds = data.challenge_max_age_seconds || DEFAULT_CHALLENGE_MAX_AGE_SECONDS;
  const ids = new Set<string>();
  for (const provider of data.providers ?? []) {
    if (
      !provider.online ||
      provider.status === "untrusted" ||
      !provider.runtime_verified ||
      !provider.last_challenge_verified ||
      !challengeFresh(provider.last_challenge_verified, maxAgeSeconds)
    ) {
      continue;
    }
    for (const model of provider.models ?? []) {
      if (model.id) ids.add(model.id);
    }
  }

  return NextResponse.json({ models: [...ids].sort() });
}
