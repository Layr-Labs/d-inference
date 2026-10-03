import type { NativeModel } from '../../../../shared/contracts';
import { clamp } from './geometry';

export type MemoryKind = 'weights' | 'kv' | 'reserved';
/** A share of the interleaved unified-memory space, as fractions in [0, 1]. */
export interface MemorySegment {
  kind: MemoryKind;
  /** Loaded-model index for weights; -1 otherwise. */
  model: number;
  from: number;
  to: number;
}
export interface MemoryMap {
  totalGb: number;
  weightsGb: number;
  models: { id: string; name: string; gb: number }[];
  segments: MemorySegment[];
}
const MIN_KV_SHARE = 0.08;

export const loadedModels = (models: NativeModel[]) =>
  models
    .filter((model) => model.loaded)
    .map((model) => ({
      id: model.id,
      name: model.display_name || model.id,
      gb: Math.max(0, model.memory_gb ?? model.size_gb ?? 0),
    }));

/**
 * Unified memory is interleaved across every package, so each package holds the same split:
 * resident weights per model, room for the KV cache, and the headroom the provider leaves the
 * OS (its load cap is 90% of RAM with at least 2 GB kept back).
 */
export function memoryMap(totalGb: number, models: MemoryMap['models']): MemoryMap {
  const total = totalGb > 0 ? totalGb : 1,
    reserved = clamp(Math.max(0.1, 2 / total), 0.1, 0.3),
    weightsGb = models.reduce((sum, model) => sum + model.gb, 0),
    room = 1 - reserved - MIN_KV_SHARE,
    scale = weightsGb / total > room ? room / (weightsGb / total) : 1;
  const segments: MemorySegment[] = [];
  let at = 0;
  models.forEach((model, index) => {
    const size = (model.gb / total) * scale;
    if (size <= 0) return;
    segments.push({ kind: 'weights', model: index, from: at, to: at + size });
    at += size;
  });
  segments.push({ kind: 'kv', model: -1, from: at, to: 1 - reserved });
  segments.push({ kind: 'reserved', model: -1, from: 1 - reserved, to: 1 });
  return { totalGb: totalGb > 0 ? totalGb : 0, weightsGb, models, segments };
}
export function segmentAt(map: MemoryMap, position: number): MemorySegment {
  return (
    map.segments.find((segment) => position >= segment.from && position < segment.to) ??
    map.segments[map.segments.length - 1]
  );
}
