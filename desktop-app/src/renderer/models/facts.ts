import type { NativeModel, Snapshot } from '../../shared/contracts';
import { pinnedMemory } from './selection';

export const gigabytes = (value: number) =>
  `${Number.isInteger(value) ? value : value.toFixed(1)} GB`;

// The catalog's display name, or the id for a model the catalog doesn't list.
export const modelName = (models: NativeModel[], id: string) =>
  models.find((model) => model.id === id)?.display_name || id;

// Size on disk or to download, and the memory need once the runtime has measured it.
export function modelFacts(model: NativeModel) {
  if (!model.eligible) return model.reason || 'Not available on this Mac.';
  return [
    `${gigabytes(model.size_gb)} ${model.downloaded ? 'on disk' : 'download'}`,
    model.memory_gb !== undefined && `needs ${gigabytes(model.memory_gb)} memory`,
  ]
    .filter(Boolean)
    .join(' · ');
}

export function pinnedMemoryLine(snapshot: Snapshot, pinned: string[], noun: string) {
  const { needed, measured, exceeds } = pinnedMemory(snapshot, pinned);
  const count = `${pinned.length} ${noun}`;
  if (!needed) return { text: count, exceeds };
  const total = gigabytes(snapshot.memory.total_gb);
  const amount = `${measured ? '' : 'at least '}${gigabytes(needed)} of ${total} memory`;
  return { text: `${count} · ${amount}`, exceeds };
}
