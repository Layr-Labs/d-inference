import type { PlatformStats } from "../platform-types";
import type { ProviderStats } from "../provider-fleet";

export const hardwareProvider = (overrides: Partial<ProviderStats> = {}): ProviderStats => ({
  id: "provider", chip: "Apple M4 Pro", chip_family: "M4", chip_tier: "Pro", machine_model: "Mac mini", memory_gb: 64,
  gpu_cores: 20, cpu_cores: { total: 12, performance: 8, efficiency: 4 }, memory_bandwidth_gbs: 273,
  status: "online", trust_level: "hardware", attested: true, decode_tps: 0, requests_served: 0, tokens_generated: 0,
  ...overrides,
});
export const hardwareStats = (providers: ProviderStats[]): PlatformStats => ({
  total_requests: 0, total_prompt_tokens: 0, total_completion_tokens: 0, total_tokens: 0, avg_tokens_per_request: 0,
  active_providers: providers.length, total_gpu_cores: 0, total_cpu_cores: 0, total_memory_gb: 0,
  total_bandwidth_gbs: 0, network_capacity_tps: 0, providers, models: [], time_series: [],
});
