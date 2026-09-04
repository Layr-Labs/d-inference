import type { PlatformStats } from "../platform-types";
import type { MarkerDatum } from "@/components/stats/network-map";

export type GeographyMode = "providers" | "requests";
type ProviderBucket = NonNullable<PlatformStats["provider_locations"]>[number];
type RequestBucket = NonNullable<PlatformStats["request_locations"]>[number];
type LocationBucket = ProviderBucket | RequestBucket;

export interface GeographyPlace {
  key: string;
  label: string;
  country: string;
  countryCode: string;
  value: number;
  latitude?: number;
  longitude?: number;
}

export interface GeographyData {
  mode: GeographyMode;
  total: number;
  hasRegionTotals: boolean;
  countries: number;
  regions: GeographyPlace[];
  markers: MarkerDatum[];
  mapScope: "city" | "region";
  omittedPlaces: number;
  unknown: number;
  suppressed: number;
  privacyMinimum: number;
  period: string;
}

const MAX_MAP_LOCATIONS = 120;
const compact = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
export const formatGeoCount = (value: number) => compact.format(value);
const validCount = (value: number | undefined) => Number.isFinite(value) ? Math.max(0, value ?? 0) : 0;
const normalized = (value: string | undefined) => (value ?? "").trim().toLowerCase();

function locationIdentity(bucket: LocationBucket): string {
  // Backend keys can collide when region_code is missing. Use the full place
  // hierarchy, while allowing alternate display names for an identical code.
  return JSON.stringify([
    normalized(bucket.scope),
    normalized(bucket.country_code || bucket.country),
    normalized(bucket.region_code || bucket.region),
    normalized(bucket.city),
  ]);
}

function hasCoordinates(bucket: { latitude?: number; longitude?: number }): boolean {
  return typeof bucket.latitude === "number" && Number.isFinite(bucket.latitude)
    && typeof bucket.longitude === "number" && Number.isFinite(bucket.longitude)
    && Math.abs(bucket.latitude) <= 90 && Math.abs(bucket.longitude) <= 180
    // The coordinator serializes unresolved coordinates as (0, 0).
    && (bucket.latitude !== 0 || bucket.longitude !== 0);
}

function aggregateLocations(buckets: LocationBucket[], minimum = 0): GeographyPlace[] {
  const locations = new Map<string, GeographyPlace>();
  const coordinateWeights = new Map<string, number>();
  for (const bucket of buckets) {
    const value = validCount("requests" in bucket ? bucket.requests : bucket.providers);
    if (value <= 0 || value < minimum) continue;
    const key = locationIdentity(bucket);
    const country = bucket.country || bucket.country_code || "Unknown country";
    const label = bucket.city || bucket.region || country;
    const existing = locations.get(key);
    const place = existing ?? { key, label, country, countryCode: bucket.country_code ?? country, value: 0 };
    if (hasCoordinates(bucket)) {
      const weight = coordinateWeights.get(key) ?? 0;
      place.latitude = ((place.latitude ?? 0) * weight + bucket.latitude! * value) / (weight + value);
      place.longitude = ((place.longitude ?? 0) * weight + bucket.longitude! * value) / (weight + value);
      coordinateWeights.set(key, weight + value);
    }
    place.value += value;
    locations.set(key, place);
  }
  return [...locations.values()].sort((a, b) => b.value - a.value || a.key.localeCompare(b.key));
}

export function buildGeographyData(stats: PlatformStats, mode: GeographyMode): GeographyData {
  const providers = mode === "providers";
  const privacyMinimum = providers
    ? Math.max(1, stats.location_privacy_min_providers ?? 2)
    : Math.max(1, stats.request_location_privacy_min_requests ?? 5);
  const cities = aggregateLocations(providers ? stats.provider_locations ?? [] : stats.request_locations ?? [], privacyMinimum);
  const regions = aggregateLocations(providers ? stats.provider_regions ?? [] : stats.request_regions ?? []);
  const totalPlaces = regions.length > 0 ? regions : cities;
  const cityPoints = cities.filter(hasCoordinates);
  const mapScope = cityPoints.length > 0 ? "city" : "region";
  const allMapPoints = mapScope === "city" ? cityPoints : regions.filter(hasCoordinates);
  const mapPoints = allMapPoints.slice(0, MAX_MAP_LOCATIONS);
  const markers = mapPoints.map((place) => ({
    key: place.key,
    xPct: ((place.longitude! + 180) / 360) * 100,
    yPct: ((90 - place.latitude!) / 180) * 100,
    nodes: place.value,
    label: place.label === place.country ? place.label : `${place.label}, ${place.country}`,
    detail: `${place.value.toLocaleString()} ${mode}`,
  }));
  const requestPeriod = stats.location_window_hours ? `Last ${stats.location_window_hours} hours` : "Recent request window";
  return {
    mode,
    total: totalPlaces.reduce((sum, place) => sum + place.value, 0),
    hasRegionTotals: regions.length > 0,
    countries: new Set(totalPlaces.map((place) => normalized(place.countryCode))).size,
    regions: totalPlaces,
    markers,
    mapScope,
    omittedPlaces: Math.max(0, allMapPoints.length - MAX_MAP_LOCATIONS),
    unknown: validCount(providers ? stats.unknown_location_providers : stats.unknown_request_location_requests),
    suppressed: validCount(providers ? stats.suppressed_city_location_providers : stats.suppressed_request_city_requests),
    privacyMinimum,
    period: providers ? "Connected now" : requestPeriod,
  };
}
