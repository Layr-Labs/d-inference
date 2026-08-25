export interface HardwareAdmissionPolicy {
  version: number;
  mode: "disabled" | "shadow" | "enforce";
  min_memory_gb: number;
  min_memory_bandwidth_gbs: number;
  min_fp16_millitflops: number;
  catalog_version: string;
  grandfather_cutoff_at?: string;
}

export interface ProviderRequirementsResponse {
  policy: HardwareAdmissionPolicy;
  accepting_new_providers: boolean;
  grandfather_existing: boolean;
  metric_definitions: Record<string, string>;
}

export async function fetchProviderRequirements(
  signal?: AbortSignal
): Promise<ProviderRequirementsResponse> {
  const response = await fetch("/api/provider-requirements", { signal });
  if (!response.ok) {
    throw new Error(`Provider requirements unavailable (${response.status})`);
  }
  return response.json() as Promise<ProviderRequirementsResponse>;
}
