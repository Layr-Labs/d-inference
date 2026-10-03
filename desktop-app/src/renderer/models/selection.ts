import type { NativeModel, Snapshot } from '../../shared/contracts';

// A model already on disk starts without a download; otherwise the smallest eligible download
// gets this Mac serving soonest.
export function startingModel(snapshot: Snapshot): NativeModel | undefined {
  const eligible = snapshot.models.filter((model) => model.eligible);
  return (
    eligible.find((model) => model.downloaded) ??
    eligible.reduce<NativeModel | undefined>(
      (smallest, model) => (!smallest || model.size_gb < smallest.size_gb ? model : smallest),
      undefined,
    )
  );
}

// Pinned models stay loaded together, so their memory is totalled against the Mac's. Memory is
// known only for models the runtime has measured; an unmeasured pin can't be counted.
export function pinnedMemory(snapshot: Snapshot, pinned: string[]) {
  const chosen = snapshot.models.filter((model) => pinned.includes(model.id));
  const needed = chosen.reduce((total, model) => total + (model.memory_gb ?? 0), 0);
  return {
    needed,
    measured: chosen.every((model) => model.memory_gb !== undefined),
    exceeds: needed > snapshot.memory.total_gb,
  };
}
