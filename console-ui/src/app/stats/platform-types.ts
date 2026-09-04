import type { ProviderStats } from "./provider-fleet";
import type { TimeSeriesBucket } from "./types";

export interface ModelStats {
  id: string;
  providers: number;
}

export interface ProviderLocationBucket {
  key: string;
  scope: "city" | "region" | "country" | string;
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
}

export interface RequestLocationBucket {
  key: string;
  scope: "city" | "region" | "country" | string;
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
}

export interface FlowLocation {
  key: string;
  kind: "consumer" | "provider" | string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  latitude?: number;
  longitude?: number;
}

export interface RequestFlowBucket {
  key: string;
  from: FlowLocation;
  to: FlowLocation;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
}

export interface NetworkUtilization {
  utilization: number;
  warm_utilization?: number;
  token_budget_utilization?: number;
  bottleneck_utilization?: number;
  bottleneck_model?: string;
  capacity_tps?: number;
  active_requests?: number;
  queued_requests?: number;
}

export interface PlatformStats {
  total_requests: number;
  total_prompt_tokens: number;
  total_completion_tokens: number;
  total_tokens: number;
  last_24h_requests?: number;
  last_24h_prompt_tokens?: number;
  last_24h_completion_tokens?: number;
  last_24h_total_tokens?: number;
  location_window_hours?: number;
  avg_tokens_per_request: number;
  active_providers: number;
  total_gpu_cores: number;
  total_cpu_cores: number;
  total_memory_gb: number;
  total_bandwidth_gbs: number;
  network_capacity_tps: number;
  active_power_watts?: number;
  network_utilization?: NetworkUtilization;
  providers: ProviderStats[];
  models: ModelStats[];
  provider_locations?: ProviderLocationBucket[];
  provider_regions?: ProviderLocationBucket[];
  unknown_location_providers?: number;
  suppressed_city_location_providers?: number;
  location_privacy_min_providers?: number;
  request_locations?: RequestLocationBucket[];
  request_regions?: RequestLocationBucket[];
  request_flows?: RequestFlowBucket[];
  unknown_request_location_requests?: number;
  suppressed_request_city_requests?: number;
  request_location_privacy_min_requests?: number;
  time_series: TimeSeriesBucket[];
}
