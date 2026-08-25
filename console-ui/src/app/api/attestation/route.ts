import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";

interface AttestationProvider {
  provider_id?: string;
  chip_name?: string;
  hardware_model?: string;
  trust_level?: string;
  status?: string;
  memory_gb?: number;
  gpu_cores?: number;
  models?: string[];
  secure_enclave?: boolean;
  sip_enabled?: boolean;
  secure_boot_enabled?: boolean;
  authenticated_root_enabled?: boolean;
  system_volume_hash?: string;
  se_public_key?: string;
  mdm_verified?: boolean;
  acme_verified?: boolean;
  mda_verified?: boolean;
  mda_os_version?: string;
  mda_sepos_version?: string;
  last_challenge_time?: string;
}

const PUBLIC_ATTESTATION_FIELDS = [
  "provider_id",
  "chip_name",
  "hardware_model",
  "trust_level",
  "status",
  "memory_gb",
  "gpu_cores",
  "models",
  "secure_enclave",
  "sip_enabled",
  "secure_boot_enabled",
  "authenticated_root_enabled",
  "system_volume_hash",
  "se_public_key",
  "mdm_verified",
  "acme_verified",
  "mda_verified",
  "mda_os_version",
  "mda_sepos_version",
  "last_challenge_time",
] as const;

function projectProvider(value: unknown): AttestationProvider | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;

  const source = value as Record<string, unknown>;
  const projected: Record<string, unknown> = {};
  for (const key of PUBLIC_ATTESTATION_FIELDS) {
    if (source[key] !== undefined) projected[key] = source[key];
  }
  return projected as AttestationProvider;
}

function projectPublicFeed(data: unknown): { providers: AttestationProvider[] } {
  if (!data || typeof data !== "object" || Array.isArray(data)) return { providers: [] };
  const providers = (data as { providers?: unknown }).providers;
  if (!Array.isArray(providers)) return { providers: [] };
  return { providers: providers.map(projectProvider).filter((p): p is AttestationProvider => p !== null) };
}

// Compute the chat banner's tiny count/timestamp shape from the redacted
// coordinator attestation status feed.
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
    const data: unknown = await response.json();

    if (!response.ok) {
      const upstreamError =
        data && typeof data === "object" && !Array.isArray(data) && typeof (data as { error?: unknown }).error === "string"
          ? (data as { error: string }).error
          : `Upstream ${response.status}`;
      return NextResponse.json(
        { error: upstreamError },
        { status: response.status },
      );
    }

    const publicFeed = projectPublicFeed(data);
    if (wantSummary) {
      // Edge-cacheable: the banner count tolerates a few seconds of staleness.
      return NextResponse.json(summarize(publicFeed), {
        headers: { "Cache-Control": cacheControl(15, 60) },
      });
    }
    return NextResponse.json(publicFeed);
  } catch (error) {
    return NextResponse.json(
      {
        error: error instanceof Error ? error.message : "Failed to load attestation",
      },
      { status: 500 },
    );
  }
}
