import { NextRequest, NextResponse } from "next/server";
import { coordinatorUrl, cacheControl } from "@/lib/server/coordinator";
import {
  MOCK_CITY_BUCKETS,
  MOCK_REGION_BUCKETS,
  MOCK_REQUEST_CITY_BUCKETS,
  MOCK_REQUEST_REGION_BUCKETS,
  MOCK_REQUEST_FLOWS,
} from "./mock-geo";

type ProviderRow = {
  id?: string;
  trust_level?: string;
  last_challenge_verified?: string;
  runtime_verified?: boolean;
  certificate_available?: boolean;
  mda_verified?: boolean;
  failed_challenges?: number;
  routable?: boolean;
  [key: string]: unknown;
};

function withMockGeography(data: Record<string, unknown>): Record<string, unknown> {
  const located = MOCK_REGION_BUCKETS.reduce((sum, bucket) => sum + bucket.providers, 0);
  const active = typeof data.active_providers === "number" ? data.active_providers : located;
  const providers = Array.isArray(data.providers)
    ? data.providers.map((provider, index) => {
      const row = provider as ProviderRow;
      const hardware = row.trust_level === "hardware";
      const certificateAvailable = row.certificate_available ?? hardware;
      const challengeVerified =
        row.last_challenge_verified ??
        new Date(Date.now() - (index % 8) * 42_000).toISOString();
      const routable =
        row.routable ??
        Boolean(hardware && certificateAvailable && row.runtime_verified !== false && challengeVerified);
      return {
        ...row,
        runtime_verified: row.runtime_verified ?? hardware,
        certificate_available: certificateAvailable,
        mda_verified: row.mda_verified ?? (hardware && index % 3 === 0),
        last_challenge_verified: challengeVerified,
        failed_challenges: row.failed_challenges ?? 0,
        routable,
      };
    })
    : data.providers;
  return {
    ...data,
    providers,
    provider_locations: MOCK_CITY_BUCKETS,
    provider_regions: MOCK_REGION_BUCKETS,
    unknown_location_providers: Math.max(0, active - located),
    suppressed_city_location_providers: 3,
    location_privacy_min_providers: 2,
    request_locations: MOCK_REQUEST_CITY_BUCKETS,
    request_regions: MOCK_REQUEST_REGION_BUCKETS,
    request_flows: MOCK_REQUEST_FLOWS,
    unknown_request_location_requests: 640,
    suppressed_request_city_requests: 17,
    request_location_privacy_min_requests: 5,
  };
}

export async function GET(req: NextRequest) {
  if (req.nextUrl.searchParams.get("mock") === "geo") {
    // Mock mode: try upstream but fall back to empty base so dev works offline.
    const res = await fetch(`${coordinatorUrl()}/v1/stats`, { cache: "no-store" }).catch(() => null);
    const data = res?.ok ? await res.json() : {};
    return NextResponse.json(withMockGeography(data));
  }
  const res = await fetch(`${coordinatorUrl()}/v1/stats`, { cache: "no-store" });
  if (!res.ok) {
    return NextResponse.json(
      { error: `Upstream ${res.status}` },
      { status: res.status },
    );
  }
  return NextResponse.json(await res.json(), {
    headers: { "Cache-Control": cacheControl(10, 30) },
  });
}
