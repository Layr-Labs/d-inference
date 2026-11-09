import type { NativeModel, Snapshot } from '../../shared/contracts';
import { pinnedMemory } from './selection';

export const gigabytes = (value: number) =>
  `${Number.isInteger(value) ? value : value.toFixed(1)} GB`;

// The catalog's display name, or the id for a model the catalog doesn't list.
export const modelName = (models: NativeModel[], id: string) =>
  models.find((model) => model.id === id)?.display_name || id;

// Size on disk or to download, and the memory need once the runtime has measured it. `network`
// asks whether the model can serve Darkbloom, which a model found only on disk never can.
export function modelFacts(model: NativeModel, network = false) {
  if (!model.eligible) return model.reason || 'Not available on this Mac.';
  if (network && model.network === false) return 'Not on the Darkbloom network. Runs with Only me.';
  return [
    `${gigabytes(model.size_gb)} ${model.downloaded ? 'on disk' : 'download'}`,
    model.memory_gb != null && `needs ${gigabytes(model.memory_gb)} memory`,
  ]
    .filter(Boolean)
    .join(' · ');
}

// Whether the network knows this Mac has the model. Selected or downloaded is not enough: only a
// model the live registration carries gets requests. `expected` is true for a model this Mac
// should register, so its absence is a warning; otherwise absence is not shown.
export function registrationLine(model: NativeModel, expected: boolean) {
  switch (model.registration) {
    case 'routable':
      return { text: 'Registered with the network', warning: false };
    case 'autopilot':
      return { text: 'Registered for Autopilot', warning: false };
    case 'none':
      return expected ? { text: 'Not registered with the network yet', warning: true } : undefined;
    default:
      return undefined;
  }
}

export function pinnedMemoryLine(snapshot: Snapshot, pinned: string[], noun: string) {
  const { needed, measured, exceeds, limit } = pinnedMemory(snapshot, pinned);
  const count = `${pinned.length} ${noun}`;
  if (!needed) return { text: count, exceeds, limit };
  const total = gigabytes(snapshot.memory.total_gb);
  const amount = `${measured ? '' : 'at least '}${gigabytes(needed)} of ${total} memory`;
  return { text: `${count} · ${amount}`, exceeds, limit };
}
