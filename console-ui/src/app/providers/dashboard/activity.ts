import type { MyProvider } from "../types";

/** Slots are authoritative, including an empty snapshot. Offline data is historical. */
export function loadedModels(provider: MyProvider): string[] {
  if (!provider.online) return [];
  if (provider.backend_capacity) {
    return [...new Set(provider.backend_capacity.slots
      .filter((slot) => slot.state === "running" || slot.state === "idle")
      .map((slot) => slot.model))];
  }
  return [...new Set(provider.warm_models ?? (provider.current_model ? [provider.current_model] : []))];
}

export function fleetActivity(providers: MyProvider[]) {
  const online = providers.filter((provider) => provider.online);
  const models = new Set(online.flatMap(loadedModels));
  const memoryReported = online.filter((provider) => (provider.hardware.memory_gb ?? 0) > 0);
  const capacities = online.flatMap((provider) => provider.backend_capacity ? [provider.backend_capacity] : []);
  return {
    online: online.length,
    serving: online.filter((provider) => provider.status === "serving").length,
    requests: online.reduce((sum, provider) => sum + provider.pending_requests, 0),
    queued: capacities.reduce((sum, cap) => sum + cap.slots.reduce((n, slot) => n + slot.num_waiting, 0), 0),
    queueReported: capacities.length,
    loadedModels: models.size,
    loadedCopies: online.reduce((sum, provider) => sum + loadedModels(provider).length, 0),
    memoryGB: memoryReported.reduce((sum, provider) => sum + (provider.hardware.memory_gb ?? 0), 0),
    memoryReported: memoryReported.length,
    lifetimeRequests: providers.reduce((sum, provider) => sum + provider.lifetime_requests_served, 0),
    lifetimeTokens: providers.reduce((sum, provider) => sum + provider.lifetime_tokens_generated, 0),
  };
}
