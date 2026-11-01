import type { CoreKind, HardwareTopology } from '../../../../shared/hardware';
import { chipAnatomy, gpuGroups, type ChipAnatomy, type CoreCluster } from './anatomy';
import { share } from './geometry';

const KIND_RANK: Record<CoreKind, number> = { super: 0, performance: 1, efficiency: 2 };
const isKind = (kind: unknown): kind is CoreKind => typeof kind === 'string' && kind in KIND_RANK;
const positive = (value: number | null | undefined): value is number =>
  typeof value === 'number' && Number.isFinite(value) && value > 0;
const sum = (values: number[]) => values.reduce((total, value) => total + value, 0);

/** Clusters of one kind split across dies in order, so an Ultra's first half sits on die 0. */
function assignDies(clusters: Omit<CoreCluster, 'die'>[], dies: number): CoreCluster[] {
  const seen: Partial<Record<CoreKind, number>> = {};
  return clusters.map((cluster) => {
    const ofKind = clusters.filter((other) => other.kind === cluster.kind).length,
      index = (seen[cluster.kind] = (seen[cluster.kind] ?? -1) + 1);
    return { ...cluster, die: Math.min(dies - 1, Math.floor((index * dies) / ofKind)) };
  });
}

/**
 * Reported clusters, or one cluster per tier when only tier counts are known (their logical
 * ids are then unknown, so the cores cannot be lit individually).
 */
function measuredClusters({ cpu }: HardwareTopology, dies: number) {
  const reported = (cpu.clusters ?? [])
    .filter((cluster) => isKind(cluster.kind) && cluster.cpus?.length)
    .map((cluster) => ({ id: cluster.id, kind: cluster.kind, cpus: cluster.cpus }));
  const clusters = reported.length
    ? reported
        .sort((a, b) => KIND_RANK[a.kind] - KIND_RANK[b.kind] || a.id - b.id)
        .map(({ kind, cpus }) => ({ kind, cores: cpus.length, cpus }))
    : (cpu.tiers ?? [])
        .filter((tier) => isKind(tier.kind) && positive(tier.cores))
        .sort((a, b) => KIND_RANK[a.kind] - KIND_RANK[b.kind])
        .flatMap((tier) =>
          Array.from({ length: dies }, (_, die) => ({
            kind: tier.kind,
            cores: share(tier.cores, dies, die),
            cpus: [] as number[],
          })),
        )
        .filter((cluster) => cluster.cores > 0);
  return assignDies(clusters, dies);
}

/**
 * The chip as this Mac reports it: real CPU clusters and tiers (including Super cores), GPU
 * core count and partitions, memory size and peak bandwidth. The estimate fills whatever the
 * topology leaves out, and stands in entirely while no topology has arrived.
 */
export function anatomyFromTopology(
  topology: HardwareTopology | null,
  chip: string,
  memoryGb: number,
): ChipAnatomy {
  if (!topology) return chipAnatomy(chip, memoryGb);
  const estimate = chipAnatomy(
      topology.chip?.trim() || chip,
      positive(topology.memory?.total_gb) ? topology.memory.total_gb : memoryGb,
    ),
    clusters = measuredClusters(topology, estimate.dies);
  const cores = (kind: CoreKind) =>
    sum(clusters.filter((cluster) => cluster.kind === kind).map((cluster) => cluster.cores));
  const groups = (topology.gpu?.groups ?? []).filter(positive),
    reportedCores = positive(topology.gpu?.cores) ? topology.gpu.cores : null,
    gpuCores = reportedCores ?? (groups.length ? sum(groups) : estimate.gpuCores),
    partitions = groups.length && sum(groups) === gpuCores ? groups : [gpuCores];
  return {
    ...estimate,
    source: 'topology',
    ...(clusters.length && {
      superCores: cores('super'),
      performanceCores: cores('performance'),
      efficiencyCores: cores('efficiency'),
      clusters,
    }),
    gpuCores,
    gpuGroups: gpuGroups(partitions, estimate.tier, estimate.dies),
    gpuMaxMhz: positive(topology.gpu?.max_mhz) ? topology.gpu.max_mhz : null,
    bandwidthGBs: positive(topology.memory?.peak_bandwidth_gbps)
      ? topology.memory.peak_bandwidth_gbps
      : estimate.bandwidthGBs,
  };
}
