import type { MyProvider } from "../types";

export interface ColdModelReadiness {
  model: string;
  estimatedGb: number;
  headroomGb: number;
  requiredGb: number;
  usableGb: number;
  shortfallGb: number;
  coldLoadShortfallGb?: number;
  busyServing: boolean;
  /** Normal request loading may evict idle slots; startup preload never does. */
  canLoadAfterEviction?: boolean;
}

/** The provider's current no-eviction load check for each advertised cold model. */
export function coldModelReadiness(
  provider: MyProvider, heartbeatTimeoutSeconds = 90, nowMs = Date.now()
): ColdModelReadiness[] {
  const cap = provider.backend_capacity;
  const capacityModelIDs = provider.capacity_model_ids;
  const usableGb = cap?.load_usable_gb;
  const headroomGb = cap?.load_headroom_gb;
  const heartbeatMs = provider.last_heartbeat ? Date.parse(provider.last_heartbeat) : NaN;
  const heartbeatAgeMs = nowMs - heartbeatMs;
  if (!provider.online || !cap || !capacityModelIDs || !Number.isFinite(heartbeatAgeMs) ||
      heartbeatAgeMs < -30_000 || heartbeatAgeMs > heartbeatTimeoutSeconds * 1000 ||
      usableGb === undefined || headroomGb === undefined ||
      !Number.isFinite(usableGb) || !Number.isFinite(headroomGb) || usableGb < 0 || headroomGb < 0) {
    return [];
  }

  const accepted = new Set(capacityModelIDs);
  // With backend capacity present, slots are authoritative. A crashed slot
  // still owns model weights, so it is not a cold-load candidate. WarmModels
  // and CurrentModel are legacy fallbacks and may lag an unload.
  const resident = new Set<string>();
  for (const slot of cap.slots) {
    if (slot.state === "idle" || slot.state === "running" || slot.state === "crashed") {
      resident.add(slot.model);
    }
  }
  const busyServing = provider.pending_requests > 0 || cap.load_transition_active === true ||
    cap.slots.some((slot) => slot.state === "running" || slot.state === "reloading" || slot.num_running > 0);

  return provider.models.flatMap((model) => {
    const estimatedGb = model.estimated_memory_gb;
    if (!accepted.has(model.id) || resident.has(model.id) || estimatedGb === undefined ||
        !Number.isFinite(estimatedGb) || estimatedGb <= 0) return [];
    const requiredGb = estimatedGb + headroomGb;
    const evictionAwareGb = cap?.free_for_load_gb;
    const hasEvictionSample = evictionAwareGb !== undefined &&
      Number.isFinite(evictionAwareGb) && evictionAwareGb >= 0;
    return [{
      model: model.id,
      estimatedGb,
      headroomGb,
      requiredGb,
      usableGb,
      shortfallGb: Math.max(0, requiredGb - usableGb),
      coldLoadShortfallGb: hasEvictionSample ? Math.max(0, estimatedGb - evictionAwareGb) : undefined,
      busyServing,
      canLoadAfterEviction: hasEvictionSample ? evictionAwareGb >= estimatedGb : undefined,
    }];
  });
}
