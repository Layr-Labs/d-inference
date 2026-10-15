import type { NativeModel, Snapshot } from '../../shared/contracts';

// Network serving and Autopilot advertise only catalog models. The model list also holds every
// model found on disk, which Local only can run but the network never routes to.
export const servesNetwork = (model: NativeModel) => model.eligible && model.network !== false;

// A model already on disk starts without a download; otherwise the smallest eligible download
// gets this Mac serving soonest.
export function startingModel(snapshot: Snapshot): NativeModel | undefined {
  const eligible = snapshot.models.filter(servesNetwork);
  return (
    eligible.find((model) => model.downloaded) ??
    eligible.reduce<NativeModel | undefined>(
      (smallest, model) => (!smallest || model.size_gb < smallest.size_gb ? model : smallest),
      undefined,
    )
  );
}

// Pinned models stay loaded together, so their memory is totalled against the Mac's, and the
// runtime keeps at most `max_model_slots` models loaded. Memory is known only for models the
// runtime has measured; an unmeasured pin can't be counted. `limit` says which one is exceeded.
export function pinnedMemory(snapshot: Snapshot, pinned: string[]) {
  const chosen = snapshot.models.filter((model) => pinned.includes(model.id));
  const needed = chosen.reduce((total, model) => total + (model.memory_gb ?? model.size_gb), 0);
  const slots = snapshot.memory.max_model_slots;
  const limit =
    needed > (snapshot.memory.pin_budget_gb ?? snapshot.memory.total_gb)
      ? ('memory' as const)
      : slots !== undefined && chosen.length > slots
        ? ('slots' as const)
        : undefined;
  return {
    needed,
    measured: chosen.every((model) => model.memory_gb != null),
    exceeds: !!limit,
    limit,
  };
}
