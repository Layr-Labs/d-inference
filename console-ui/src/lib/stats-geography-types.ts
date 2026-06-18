/** Shared location bucket shapes for stats geography UI. */

export interface RequestLocationBucketView {
  key: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  requests: number;
  prompt_tokens: number;
  completion_tokens: number;
  providers: number;
}

export interface ProviderLocationBucketView {
  key: string;
  city?: string;
  region?: string;
  region_code?: string;
  country?: string;
  country_code?: string;
  providers: number;
  hardware_attested: number;
  gpu_cores: number;
  memory_gb: number;
}
