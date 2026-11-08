import type { CoreKind } from '../../../../shared/hardware';
import type { ChipTier, CoreCluster } from './anatomy';
import { columns, fitGrid, grid, inset, rows, share, type Rect, type Side } from './geometry';

export type BlockKind = 'cpu' | 'gpu' | 'interface';
export type TileKind = 'gpu' | CoreKind | 'l2';
export interface DieBlock extends Rect {
  kind: BlockKind;
  label: string;
  /** Inner area below the label band, where the block's tiles sit. */
  body: Rect;
  side?: Side;
}
export interface DieTile extends Rect {
  kind: TileKind;
  /** Physically present but not counted: binned or shared logic. */
  filler: boolean;
  /** Logical CPU id of a core, -1 when unknown. */
  cpu?: number;
  /** Index into the anatomy's clusters, for CPU cores and their L2. */
  cluster?: number;
}
export interface DieCluster extends CoreCluster {
  index: number;
  /** Core slots drawn: the largest cluster of the kind, so binned cores show as fillers. */
  slots: number;
}
export interface DieSpec {
  tier: ChipTier;
  clusters: DieCluster[];
  /** This die's GPU partitions, at least one per GPU half. */
  gpuGroups: number[];
  /** Cores drawn per partition: the chip's largest, so binned cores show as fillers. */
  gpuSlots: number;
}
export const BLOCK_LABELS: Record<BlockKind, string> = {
  cpu: 'CPU',
  gpu: 'GPU',
  interface: 'Memory interface',
};

/**
 * One die in its canonical frame: memory interface strips on the left/right edges
 * (right only for base chips), with GPU wings beside the CPU column.
 */
export function canonicalDie(spec: DieSpec, w: number, h: number) {
  const blocks: DieBlock[] = [],
    tiles: DieTile[] = [];
  const gap = h * 0.014,
    band = h * 0.062,
    inner = inset({ x: 0, y: 0, w, h }, h * 0.026);
  const block = (rect: Rect, kind: BlockKind, labelled = true, side?: Side) => {
    const body = labelled
      ? inset({ ...rect, y: rect.y + band, h: rect.h - band }, gap * 0.5)
      : inset(rect, gap * 0.5);
    blocks.push({ ...rect, kind, label: BLOCK_LABELS[kind], body, side });
    return body;
  };
  const place = (cells: Rect[], kind: TileKind, count: number) =>
    cells.forEach((cell, i) => tiles.push({ ...cell, kind, filler: i >= count }));

  const double = spec.tier !== 'base',
    phy = h * 0.032,
    gpuWidth = w * (spec.tier === 'base' ? 0.36 : spec.tier === 'pro' ? 0.24 : 0.27);
  const centreWidth =
    inner.w - (double ? 2 * (phy + gpuWidth) + 4 * gap : gpuWidth + phy + 2 * gap);
  const parts = columns(
    inner,
    double ? [phy, gpuWidth, centreWidth, gpuWidth, phy] : [centreWidth, gpuWidth, phy],
    gap,
  );
  const interfaces = double ? [parts[0], parts[4]] : [parts[2]],
    gpus = double ? [parts[1], parts[3]] : [parts[1]],
    centre = double ? parts[2] : parts[0];

  interfaces.forEach((rect, i) =>
    block(rect, 'interface', false, double && i === 0 ? 'left' : 'right'),
  );
  let group = 0;
  gpus.forEach((half, i) => {
    const body = block(half, 'gpu'),
      count = share(spec.gpuGroups.length, gpus.length, i),
      partitions = spec.gpuGroups.slice(group, (group += count));
    rows(body, Array(count).fill(1), gap * 1.8).forEach((area, g) => {
      const shape = fitGrid(spec.gpuSlots, area, 1.3);
      place(grid(area, shape.cols, shape.rows, gap * 0.8), 'gpu', partitions[g]);
    });
  });

  cpuClusters(spec.clusters, block(centre, 'cpu'), gap, tiles);
  return { blocks, tiles };
}

const CORE_ASPECT = 1.1;
const aspectError = (w: number, h: number) => Math.abs(Math.log(w / h / CORE_ASPECT));
/** Relative footprint per core: Super and Performance cores dwarf Efficiency cores. */
const CORE_AREA: Record<CoreKind, number> = { super: 1.15, performance: 1, efficiency: 0.62 };

/**
 * A cluster sandwiches its shared L2 between two rows (or columns) of cores, whichever keeps
 * the cores closest to square.
 */
function clusterCells(rect: Rect, cluster: DieCluster, gap: number) {
  const perSide = Math.ceil(cluster.slots / 2),
    weights = cluster.kind === 'efficiency' ? [0.34, 0.32, 0.34] : [0.37, 0.26, 0.37];
  const stacked = aspectError(rect.w / perSide, rect.h * weights[0]),
    sideBySide = aspectError(rect.w * weights[0], rect.h / perSide);
  const [first, l2, second] =
    stacked <= sideBySide ? rows(rect, weights, gap) : columns(rect, weights, gap);
  const cores = [first, second].flatMap((side) =>
    stacked <= sideBySide
      ? columns(side, Array(perSide).fill(1), gap)
      : rows(side, Array(perSide).fill(1), gap),
  );
  return { cores, l2, error: Math.min(stacked, sideBySide) };
}

function cpuClusters(clusters: DieCluster[], area: Rect, gap: number, tiles: DieTile[]) {
  if (!clusters.length) return;
  // Clusters sit side by side or stacked, whichever yields better-proportioned cores.
  const arrangements = [columns, rows].map((split) => {
    const rects = split(
      area,
      clusters.map((cluster) => Math.ceil(cluster.slots / 2) * CORE_AREA[cluster.kind]),
      gap * 1.4,
    );
    const cells = rects.map((rect, i) => clusterCells(rect, clusters[i], gap * 0.7));
    return { cells, error: Math.max(...cells.map((cell) => cell.error)) };
  });
  const best = arrangements[0].error <= arrangements[1].error ? arrangements[0] : arrangements[1];
  best.cells.forEach(({ cores, l2 }, i) => {
    const cluster = clusters[i];
    cores.forEach((cell, slot) =>
      tiles.push({
        ...cell,
        kind: cluster.kind,
        filler: slot >= cluster.cores,
        cpu: slot < cluster.cores ? (cluster.cpus[slot] ?? -1) : -1,
        cluster: cluster.index,
      }),
    );
    tiles.push({ ...l2, kind: 'l2', filler: false, cpu: -1, cluster: cluster.index });
  });
}
