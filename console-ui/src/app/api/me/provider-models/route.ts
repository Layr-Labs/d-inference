import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, privyAuth, missingPrivyToken } from "@/lib/server/coordinator";

type SelfRouteModelsResponse = { models?: unknown };

// Thin proxy over the coordinator's alias-aware self-route model view. The
// coordinator owns the eligibility filter (online, runtime-verified, fresh
// challenge, private-text support, owner weight-hash servability) AND the
// alias translation: catalog builds behind a public alias come back as the
// alias id — the exact id a self-route key's clients will list and request.
// Deriving this list client-side from raw /v1/me/providers advertisements
// produced allow-lists holding hidden build ids that the coordinator's
// allow-list check (which runs on the requested name, before alias
// resolution) then rejected.
export async function GET(req: NextRequest) {
  const authHeader = privyAuth(req);
  if (!authHeader) return missingPrivyToken();

  const res = await fetch(`${coordinatorUrl()}/v1/me/self-route-models`, {
    headers: { Authorization: authHeader },
    cache: "no-store",
  });
  if (!res.ok) {
    const text = await res.text();
    return NextResponse.json({ error: text || `Upstream ${res.status}` }, { status: res.status });
  }

  const data = (await res.json()) as SelfRouteModelsResponse;
  const models = Array.isArray(data.models)
    ? data.models.filter((m): m is string => typeof m === "string" && m.length > 0)
    : [];
  return NextResponse.json({ models });
}
