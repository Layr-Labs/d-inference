import type { MyProvider } from "../types";

export interface ColdModelReadiness {
  model: string;
  estimatedGb: number;
  headroomGb: number;
  requiredGb: number;
  usableGb: number;
  shortfallGb: number;
  /** Normal request loading may evict idle slots; startup preload never does. */
  canLoadAfterEviction?: boolean;
}

/** The provider's current no-eviction load check for each advertised cold model. */
export function coldModelReadiness(provider: MyProvider): ColdModelReadiness[] {
  const cap = provider.backend_capacity;
  const usableGb = cap?.load_usable_gb;
  const headroomGb = cap?.load_headroom_gb;
  if (!provider.online || usableGb === undefined || headroomGb === undefined ||
      !Number.isFinite(usableGb) || !Number.isFinite(headroomGb) || usableGb < 0 || headroomGb < 0) {
    return [];
  }

  const resident = new Set(provider.warm_models ?? []);
  if (provider.current_model) resident.add(provider.current_model);
  for (const slot of cap?.slots ?? []) {
    if (slot.state === "idle" || slot.state === "running") resident.add(slot.model);
  }

  return provider.models.flatMap((model) => {
    const estimatedGb = model.estimated_memory_gb;
    if (resident.has(model.id) || estimatedGb === undefined ||
        !Number.isFinite(estimatedGb) || estimatedGb <= 0) return [];
    const requiredGb = estimatedGb + headroomGb;
    return [{
      model: model.id,
      estimatedGb,
      headroomGb,
      requiredGb,
      usableGb,
      shortfallGb: Math.max(0, requiredGb - usableGb),
      canLoadAfterEviction: cap?.free_for_load_gb === undefined ||
        !Number.isFinite(cap.free_for_load_gb) || cap.free_for_load_gb < 0
        ? undefined : cap.free_for_load_gb >= estimatedGb,
    }];
  });
}
