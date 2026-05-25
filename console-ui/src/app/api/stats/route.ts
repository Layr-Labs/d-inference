import { NextRequest, NextResponse } from "next/server";

const COORD_URL =
  process.env.NEXT_PUBLIC_COORDINATOR_URL || "https://api.darkbloom.dev";

type LocationBucket = {
  key: string;
  scope: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
  providers: number;
  hardware_attested: number;
  gpu_cores: number;
  memory_gb: number;
  models?: string[];
};

type RequestLocationBucket = {
  key: string;
  scope: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  providers: number;
};

type FlowLocation = {
  key: string;
  kind: "consumer" | "provider";
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
};

type RequestFlowBucket = {
  key: string;
  from: FlowLocation;
  to: FlowLocation;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
};

type ProviderRow = {
  id?: string;
  trust_level?: string;
  last_challenge_verified?: string;
  runtime_verified?: boolean;
  certificate_available?: boolean;
  mda_verified?: boolean;
  acme_verified?: boolean;
  failed_challenges?: number;
  routable?: boolean;
  [key: string]: unknown;
};

const MOCK_MODELS = [
  "mlx-community/gemma-4-26b-a4b-it-8bit",
  "mlx-community/Trinity-Mini-8bit",
  "qwen3.5-27b-claude-opus-8bit",
];
const UNITED_STATES = "United States";

const MOCK_CITY_BUCKETS: LocationBucket[] = [
  {
    key: "us|ca|san francisco",
    scope: "city",
    city: "San Francisco",
    region: "California",
    region_code: "CA",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 37.7749,
    longitude: -122.4194,
    providers: 12,
    hardware_attested: 9,
    gpu_cores: 520,
    memory_gb: 1536,
    models: [MOCK_MODELS[0], MOCK_MODELS[1]],
  },
  {
    key: "us|ny|new york",
    scope: "city",
    city: "New York",
    region: "New York",
    region_code: "NY",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 40.7128,
    longitude: -74.006,
    providers: 8,
    hardware_attested: 7,
    gpu_cores: 348,
    memory_gb: 1024,
    models: [MOCK_MODELS[0]],
  },
  {
    key: "gb|eng|london",
    scope: "city",
    city: "London",
    region: "England",
    region_code: "ENG",
    country: "United Kingdom",
    country_code: "GB",
    latitude: 51.5072,
    longitude: -0.1276,
    providers: 6,
    hardware_attested: 5,
    gpu_cores: 220,
    memory_gb: 704,
    models: [MOCK_MODELS[1], MOCK_MODELS[2]],
  },
  {
    key: "ca|on|toronto",
    scope: "city",
    city: "Toronto",
    region: "Ontario",
    region_code: "ON",
    country: "Canada",
    country_code: "CA",
    latitude: 43.6532,
    longitude: -79.3832,
    providers: 5,
    hardware_attested: 4,
    gpu_cores: 170,
    memory_gb: 512,
    models: [MOCK_MODELS[0]],
  },
  {
    key: "de|be|berlin",
    scope: "city",
    city: "Berlin",
    region: "Berlin",
    region_code: "BE",
    country: "Germany",
    country_code: "DE",
    latitude: 52.52,
    longitude: 13.405,
    providers: 4,
    hardware_attested: 3,
    gpu_cores: 146,
    memory_gb: 384,
    models: [MOCK_MODELS[2]],
  },
  {
    key: "jp|13|tokyo",
    scope: "city",
    city: "Tokyo",
    region: "Tokyo",
    region_code: "13",
    country: "Japan",
    country_code: "JP",
    latitude: 35.6762,
    longitude: 139.6503,
    providers: 3,
    hardware_attested: 3,
    gpu_cores: 112,
    memory_gb: 384,
    models: [MOCK_MODELS[1]],
  },
  {
    key: "sg|sg|singapore",
    scope: "city",
    city: "Singapore",
    region: "Singapore",
    region_code: "SG",
    country: "Singapore",
    country_code: "SG",
    latitude: 1.3521,
    longitude: 103.8198,
    providers: 2,
    hardware_attested: 2,
    gpu_cores: 80,
    memory_gb: 256,
    models: [MOCK_MODELS[0]],
  },
];

const MOCK_REGION_BUCKETS: LocationBucket[] = [
  {
    key: "us|ca",
    scope: "region",
    region: "California",
    region_code: "CA",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 36.7783,
    longitude: -119.4179,
    providers: 16,
    hardware_attested: 12,
    gpu_cores: 668,
    memory_gb: 2048,
    models: [MOCK_MODELS[0], MOCK_MODELS[1]],
  },
  {
    key: "us|ny",
    scope: "region",
    region: "New York",
    region_code: "NY",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 43.2994,
    longitude: -74.2179,
    providers: 8,
    hardware_attested: 7,
    gpu_cores: 348,
    memory_gb: 1024,
    models: [MOCK_MODELS[0]],
  },
  ...MOCK_CITY_BUCKETS.slice(2).map((bucket) => ({
    ...bucket,
    key: `${bucket.country_code?.toLowerCase()}|${bucket.region_code?.toLowerCase()}`,
    scope: "region",
    city: undefined,
  })),
  {
    key: "us|wa",
    scope: "region",
    region: "Washington",
    region_code: "WA",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 47.7511,
    longitude: -120.7401,
    providers: 4,
    hardware_attested: 3,
    gpu_cores: 154,
    memory_gb: 512,
    models: [MOCK_MODELS[1]],
  },
  {
    key: "us|tx",
    scope: "region",
    region: "Texas",
    region_code: "TX",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 31.9686,
    longitude: -99.9018,
    providers: 3,
    hardware_attested: 2,
    gpu_cores: 96,
    memory_gb: 256,
    models: [MOCK_MODELS[2]],
  },
];

const MOCK_REQUEST_CITY_BUCKETS: RequestLocationBucket[] = [
  {
    key: "us|ca|san francisco",
    scope: "city",
    city: "San Francisco",
    region: "California",
    region_code: "CA",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 37.7749,
    longitude: -122.4194,
    requests: 4200,
    prompt_tokens: 7440000,
    completion_tokens: 6110000,
    providers: 24,
  },
  {
    key: "us|ny|new york",
    scope: "city",
    city: "New York",
    region: "New York",
    region_code: "NY",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 40.7128,
    longitude: -74.006,
    requests: 3100,
    prompt_tokens: 4980000,
    completion_tokens: 4380000,
    providers: 18,
  },
  {
    key: "gb|eng|london",
    scope: "city",
    city: "London",
    region: "England",
    region_code: "ENG",
    country: "United Kingdom",
    country_code: "GB",
    latitude: 51.5072,
    longitude: -0.1276,
    requests: 2200,
    prompt_tokens: 3120000,
    completion_tokens: 2410000,
    providers: 15,
  },
  {
    key: "jp|13|tokyo",
    scope: "city",
    city: "Tokyo",
    region: "Tokyo",
    region_code: "13",
    country: "Japan",
    country_code: "JP",
    latitude: 35.6762,
    longitude: 139.6503,
    requests: 1450,
    prompt_tokens: 2210000,
    completion_tokens: 1680000,
    providers: 8,
  },
  {
    key: "de|be|berlin",
    scope: "city",
    city: "Berlin",
    region: "Berlin",
    region_code: "BE",
    country: "Germany",
    country_code: "DE",
    latitude: 52.52,
    longitude: 13.405,
    requests: 980,
    prompt_tokens: 1390000,
    completion_tokens: 870000,
    providers: 7,
  },
  {
    key: "sg|sg|singapore",
    scope: "city",
    city: "Singapore",
    region: "Singapore",
    region_code: "SG",
    country: "Singapore",
    country_code: "SG",
    latitude: 1.3521,
    longitude: 103.8198,
    requests: 760,
    prompt_tokens: 1030000,
    completion_tokens: 640000,
    providers: 5,
  },
  {
    key: "in|mh|mumbai",
    scope: "city",
    city: "Mumbai",
    region: "Maharashtra",
    region_code: "MH",
    country: "India",
    country_code: "IN",
    latitude: 19.076,
    longitude: 72.8777,
    requests: 2600,
    prompt_tokens: 3820000,
    completion_tokens: 2910000,
    providers: 9,
  },
  {
    key: "fr|idf|paris",
    scope: "city",
    city: "Paris",
    region: "Ile-de-France",
    region_code: "IDF",
    country: "France",
    country_code: "FR",
    latitude: 48.8566,
    longitude: 2.3522,
    requests: 1250,
    prompt_tokens: 1910000,
    completion_tokens: 1220000,
    providers: 6,
  },
  {
    key: "mx|cmx|mexico city",
    scope: "city",
    city: "Mexico City",
    region: "Ciudad de Mexico",
    region_code: "CMX",
    country: "Mexico",
    country_code: "MX",
    latitude: 19.4326,
    longitude: -99.1332,
    requests: 1050,
    prompt_tokens: 1440000,
    completion_tokens: 910000,
    providers: 5,
  },
];

const MOCK_REQUEST_REGION_BUCKETS: RequestLocationBucket[] = [
  {
    key: "us|ca",
    scope: "region",
    region: "California",
    region_code: "CA",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 36.7783,
    longitude: -119.4179,
    requests: 5300,
    prompt_tokens: 9110000,
    completion_tokens: 7410000,
    providers: 31,
  },
  {
    key: "us|ny",
    scope: "region",
    region: "New York",
    region_code: "NY",
    country: UNITED_STATES,
    country_code: "US",
    latitude: 43.2994,
    longitude: -74.2179,
    requests: 3100,
    prompt_tokens: 4980000,
    completion_tokens: 4380000,
    providers: 18,
  },
  ...MOCK_REQUEST_CITY_BUCKETS.slice(2).map((bucket) => ({
    ...bucket,
    key: `${bucket.country_code?.toLowerCase()}|${bucket.region_code?.toLowerCase()}`,
    scope: "region",
    city: undefined,
  })),
];

function flowLocation(kind: "consumer" | "provider", bucket: LocationBucket | RequestLocationBucket): FlowLocation {
  return {
    key: `${kind}:${bucket.key}`,
    kind,
    city: bucket.city,
    region: bucket.region,
    region_code: bucket.region_code,
    country: bucket.country,
    country_code: bucket.country_code,
    latitude: bucket.latitude,
    longitude: bucket.longitude,
  };
}

function mockFlow(
  from: RequestLocationBucket,
  to: LocationBucket,
  requests: number,
  promptTokens: number,
  completionTokens: number,
): RequestFlowBucket {
  return {
    key: `${from.key}->${to.key}`,
    from: flowLocation("consumer", from),
    to: flowLocation("provider", to),
    requests,
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
  };
}

const MOCK_REQUEST_FLOWS: RequestFlowBucket[] = [
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[1], MOCK_CITY_BUCKETS[0], 1800, 2840000, 2440000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[6], MOCK_CITY_BUCKETS[6], 1560, 2210000, 1680000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[2], MOCK_CITY_BUCKETS[0], 1220, 1740000, 1320000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[0], MOCK_CITY_BUCKETS[1], 960, 1660000, 1210000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[3], MOCK_CITY_BUCKETS[0], 920, 1410000, 1080000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[7], MOCK_CITY_BUCKETS[2], 780, 1210000, 760000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[4], MOCK_CITY_BUCKETS[2], 740, 960000, 620000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[5], MOCK_CITY_BUCKETS[5], 620, 820000, 500000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[8], MOCK_CITY_BUCKETS[0], 560, 820000, 480000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[0], MOCK_CITY_BUCKETS[3], 540, 730000, 410000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[3], MOCK_CITY_BUCKETS[6], 420, 610000, 360000),
  mockFlow(MOCK_REQUEST_CITY_BUCKETS[2], MOCK_CITY_BUCKETS[4], 380, 540000, 300000),
];

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
        acme_verified: row.acme_verified ?? hardware,
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
    const res = await fetch(`${COORD_URL}/v1/stats`, { cache: "no-store" }).catch(() => null);
    const data = res?.ok ? await res.json() : {};
    return NextResponse.json(withMockGeography(data));
  }
  const res = await fetch(`${COORD_URL}/v1/stats`, { cache: "no-store" });
  if (!res.ok) {
    return NextResponse.json(
      { error: `Upstream ${res.status}` },
      { status: res.status },
    );
  }
  return NextResponse.json(await res.json());
}
