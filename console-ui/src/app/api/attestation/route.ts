import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

interface AttestationProvider {
  trust_level?: string;
  last_challenge_time?: string;
}

// Compute a tiny { count, last_verified } summary from the full attestation
// blob so the chat empty-state banner doesn't download the whole cert chain
// (100 KB–1 MB+) just to show a provider count + timestamp (perf F9b).
function summarize(data: { providers?: AttestationProvider[] }): { count: number; last_verified: string | null } {
  const attested = (data.providers || []).filter((p) => p.trust_level === "hardware");
  let lastTime = 0;
  for (const p of attested) {
    if (p.last_challenge_time) {
      const t = new Date(p.last_challenge_time).getTime();
      if (Number.isFinite(t) && t > lastTime) lastTime = t;
    }
  }
  return { count: attested.length, last_verified: lastTime ? new Date(lastTime).toISOString() : null };
}

export async function GET(req: NextRequest) {
  const wantSummary = req.nextUrl.searchParams.get("summary") === "1";
  try {
    const response = await fetch(`${coordinatorUrl()}/v1/providers/attestation`, {
      cache: "no-store",
    });
    const data = await response.json();

    if (!response.ok) {
      return NextResponse.json(
        { error: data?.error || `Upstream ${response.status}` },
        { status: response.status },
      );
    }

    if (wantSummary) {
      // Edge-cacheable: the banner count tolerates a few seconds of staleness.
      return NextResponse.json(summarize(data), {
        headers: { "Cache-Control": cacheControl(15, 60) },
      });
    }
    return NextResponse.json(data);
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Failed to load attestation",
      },
      { status: 500 },
    );
  }
}
