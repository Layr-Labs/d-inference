import type { CoreKind } from '../../../../shared/hardware';
import { share } from './geometry';

export type ChipTier = 'base' | 'pro' | 'max' | 'ultra';
/** CPU cores sharing one L2. `cpus` are logical CPU ids, empty when the ids are unknown. */
export interface CoreCluster {
  kind: CoreKind;
  cores: number;
  cpus: number[];
  die: number;
}
/**
 * The chip as drawn. `estimate` anatomies use top-bin figures that vary by configuration, so
 * they shape the illustration but are never shown as facts; `topology` anatomies carry the
 * core counts, clusters and GPU groups this Mac reports.
 */
export interface ChipAnatomy {
  source: 'topology' | 'estimate';
  name: string;
  family: string;
  generation: number;
  tier: ChipTier;
  known: boolean;
  superCores: number;
  performanceCores: number;
  efficiencyCores: number;
  /** Fastest kind first, then by die. */
  clusters: CoreCluster[];
  gpuCores: number;
  /** Enabled cores per GPU partition, at least two per die beyond base chips. */
  gpuGroups: number[];
  /** Highest GPU clock, known only from the topology. */
  gpuMaxMhz: number | null;
  neuralCores: number;
  dies: number;
  memoryPackages: number;
  bandwidthGBs: number;
  memoryGb: number;
}
type Spec = {
  p: number;
  e: number;
  gpu: number;
  packages: number;
  bandwidth: number;
};
const spec = (p: number, e: number, gpu: number, packages: number, bandwidth: number): Spec => ({
  p,
  e,
  gpu,
  packages,
  bandwidth,
});
const SPECS: Record<number, Partial<Record<ChipTier, Spec>>> = {
  1: {
    base: spec(4, 4, 8, 2, 68),
    pro: spec(8, 2, 16, 2, 200),
    max: spec(8, 2, 32, 4, 400),
    ultra: spec(16, 4, 64, 8, 800),
  },
  2: {
    base: spec(4, 4, 10, 2, 100),
    pro: spec(8, 4, 19, 2, 200),
    max: spec(8, 4, 38, 4, 400),
    ultra: spec(16, 8, 76, 8, 800),
  },
  3: {
    base: spec(4, 4, 10, 2, 100),
    pro: spec(6, 6, 18, 2, 150),
    max: spec(12, 4, 40, 4, 400),
    ultra: spec(24, 8, 80, 8, 819),
  },
  4: {
    base: spec(4, 6, 10, 2, 120),
    pro: spec(10, 4, 20, 2, 273),
    max: spec(12, 4, 40, 4, 546),
  },
  5: { base: spec(4, 6, 10, 2, 153) },
};
const LATEST = Math.max(...Object.keys(SPECS).map(Number));
const GENERIC = spec(4, 4, 8, 2, 100);

function specFor(generation: number, tier: ChipTier): Spec {
  const listed = SPECS[generation]?.[tier];
  if (listed) return listed;
  if (generation > LATEST) return specFor(LATEST, tier);
  if (tier === 'ultra') {
    const max = specFor(generation, 'max');
    return spec(max.p * 2, max.e * 2, max.gpu * 2, max.packages * 2, max.bandwidth * 2);
  }
  // A tier missing from a generation keeps the previous generation's layout, with bandwidth
  // scaled by how much the base chip's bandwidth grew between the two generations.
  for (let earlier = generation - 1; earlier >= 1; earlier--) {
    const known = SPECS[earlier]?.[tier];
    if (!known) continue;
    const growth = specFor(generation, 'base').bandwidth / specFor(earlier, 'base').bandwidth;
    return { ...known, bandwidth: Math.round(known.bandwidth * growth) };
  }
  return GENERIC;
}

export function chipAnatomy(chip: string, memoryGb: number): ChipAnatomy {
  const name = chip.trim() || 'Apple silicon';
  const match = /\bM(\d{1,2})(?:\s+(Pro|Max|Ultra))?\b/i.exec(name);
  const generation = match ? Number(match[1]) : 0;
  const known = generation >= 1;
  const tier = (known ? match![2]?.toLowerCase() || 'base' : 'base') as ChipTier;
  const chosen = known ? specFor(generation, tier) : GENERIC;
  const dies = tier === 'ultra' ? 2 : 1;
  return {
    source: 'estimate',
    name,
    family: known ? `M${generation}` : '',
    generation,
    tier,
    known,
    superCores: 0,
    performanceCores: chosen.p,
    efficiencyCores: chosen.e,
    clusters: estimatedClusters(chosen.p, chosen.e, dies),
    gpuCores: chosen.gpu,
    gpuGroups: gpuGroups([chosen.gpu], tier, dies),
    gpuMaxMhz: null,
    neuralCores: 16 * dies,
    dies,
    memoryPackages: chosen.packages,
    bandwidthGBs: chosen.bandwidth,
    memoryGb: Number.isFinite(memoryGb) && memoryGb > 0 ? memoryGb : 0,
  };
}

/** Performance cores pair into clusters of up to six; efficiency cores share one per die. */
function estimatedClusters(performance: number, efficiency: number, dies: number) {
  const clusters: CoreCluster[] = [];
  let next = 0;
  const add = (kind: CoreKind, cores: number, die: number) => {
    if (cores <= 0) return;
    clusters.push({ kind, cores, cpus: Array.from({ length: cores }, () => next++), die });
  };
  for (let die = 0; die < dies; die++) {
    const p = share(performance, dies, die),
      groups = p > 6 ? 2 : 1;
    for (let i = 0; i < groups; i++) add('performance', share(p, groups, i), die);
  }
  for (let die = 0; die < dies; die++) add('efficiency', share(efficiency, dies, die), die);
  return clusters;
}

/**
 * GPU partitions, re-split evenly when there are fewer than the dies' GPU halves (one per base
 * die, two otherwise) so every half holds at least one.
 */
export function gpuGroups(groups: number[], tier: ChipTier, dies: number) {
  const halves = (tier === 'base' ? 1 : 2) * dies,
    total = groups.reduce((sum, cores) => sum + cores, 0);
  return groups.length >= halves
    ? groups
    : Array.from({ length: halves }, (_, i) => share(total, halves, i));
}
