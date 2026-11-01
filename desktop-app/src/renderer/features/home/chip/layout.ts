import type { ChipAnatomy } from './anatomy';
import { canonicalDie, type BlockKind, type DieCluster, type TileKind } from './dieLayout';
import {
  center,
  clamp,
  orient,
  orientSide,
  share,
  union,
  type Orientation,
  type Point,
  type Rect,
  type Side,
} from './geometry';
import { wireMemory } from './memoryWiring';
import { PACKAGE_MARGIN, packagePlan } from './packagePlan';

export interface Block extends Rect {
  kind: BlockKind;
  label: string;
  die: number;
  body: Rect;
  side?: Side;
}
export interface Tile extends Rect {
  kind: TileKind;
  die: number;
  /** Index among counted tiles of the same kind across the chip; -1 for fillers. */
  index: number;
  filler: boolean;
  /** 0..1 distance from where work is dispatched (die centre, or the seam between dies). */
  dispatch: number;
  /** 0..1 distance from the nearest memory interface. */
  memory: number;
  /** Logical CPU id of a core, -1 when unknown. */
  cpu?: number;
  /** Index into the anatomy's clusters, for CPU cores and their L2. */
  cluster?: number;
}
export interface MemoryPackage extends Rect {
  index: number;
  side: Side;
  die: number;
  cols: number;
  rows: number;
  /** Row-major cells; cell i holds address range i / cells.length of the interleaved space. */
  cells: Rect[];
}
export interface PhySegment extends Rect {
  side: Side;
  die: number;
  package: number;
}
/** A substrate trace from a memory package edge to the facing memory interface. */
export interface Trace {
  from: Point;
  to: Point;
  package: number;
  lane: number;
}
export interface Die extends Rect {
  index: number;
  orientation: Orientation;
}
export interface ChipLayout {
  width: number;
  height: number;
  /** Pixels per die-edge length; scale reference for strokes and type. */
  unit: number;
  substrate: Rect;
  dies: Die[];
  bridge: Rect | null;
  blocks: Block[];
  tiles: Tile[];
  phy: PhySegment[];
  memory: MemoryPackage[];
  traces: Trace[];
  dispatch: Point;
}

const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
const rectDistance = (r: Rect, p: Point) =>
  Math.hypot(Math.max(r.x - p.x, 0, p.x - r.x - r.w), Math.max(r.y - p.y, 0, p.y - r.y - r.h));

/** Where part `index` of a `share` split begins. */
const range = (total: number, parts: number, index: number) =>
  Array.from({ length: index }, (_, i) => share(total, parts, i)).reduce((a, b) => a + b, 0);

/** Clusters indexed in anatomy order, each drawn with as many slots as its kind's largest. */
function dieClusters(anatomy: ChipAnatomy): DieCluster[] {
  const slots: Partial<Record<TileKind, number>> = {};
  for (const cluster of anatomy.clusters)
    slots[cluster.kind] = Math.max(slots[cluster.kind] ?? 0, cluster.cores);
  return anatomy.clusters.map((cluster, index) => ({
    ...cluster,
    index,
    slots: slots[cluster.kind] ?? cluster.cores,
  }));
}

/** Deterministic geometry of the chip fitted into a canvas of the given CSS size. */
export function chipLayout(
  anatomy: ChipAnatomy,
  size: { width: number; height: number },
): ChipLayout {
  const { width, height } = size,
    plan = packagePlan(anatomy.tier);
  const pad = Math.max(8, Math.min(width, height) * 0.025),
    totalW = plan.width + 2 * PACKAGE_MARGIN,
    totalH = plan.height + 2 * PACKAGE_MARGIN;
  const unit = Math.max(0, Math.min((width - 2 * pad) / totalW, (height - 2 * pad) / totalH));
  const ox = (width - totalW * unit) / 2 + PACKAGE_MARGIN * unit,
    oy = (height - totalH * unit) / 2 + PACKAGE_MARGIN * unit;
  const px = (r: Rect): Rect => ({
    x: ox + r.x * unit,
    y: oy + r.y * unit,
    w: r.w * unit,
    h: r.h * unit,
  });
  const substrate = px({ x: -PACKAGE_MARGIN, y: -PACKAGE_MARGIN, w: totalW, h: totalH });

  const blocks: Block[] = [],
    tiles: Omit<Tile, 'index' | 'dispatch' | 'memory'>[] = [];
  const clusters = dieClusters(anatomy),
    gpuSlots = Math.max(1, ...anatomy.gpuGroups),
    groupsOf = (die: number) => {
      const from = range(anatomy.gpuGroups.length, anatomy.dies, die);
      return anatomy.gpuGroups.slice(
        from,
        from + share(anatomy.gpuGroups.length, anatomy.dies, die),
      );
    };
  const dies: Die[] = plan.dies.map(({ rect, orientation }, index) => {
    const placed = px(rect),
      frame = orientation === 'none' ? { w: placed.w, h: placed.h } : { w: placed.h, h: placed.w };
    const die = canonicalDie(
      {
        tier: anatomy.tier,
        clusters: clusters.filter((cluster) => cluster.die === index),
        gpuGroups: groupsOf(index),
        gpuSlots,
      },
      frame.w,
      frame.h,
    );
    for (const block of die.blocks)
      blocks.push({
        ...block,
        ...orient(block, frame, placed, orientation),
        body: orient(block.body, frame, placed, orientation),
        side: block.side && orientSide(block.side, orientation),
        die: index,
      });
    for (const tile of die.tiles)
      tiles.push({ ...tile, ...orient(tile, frame, placed, orientation), die: index });
    return { ...placed, index, orientation };
  });

  const { memory, phy, traces } = wireMemory(
    plan.packages.map(({ rect, side }) => ({ rect: px(rect), side })),
    blocks.filter((block) => block.kind === 'interface'),
    unit,
  );
  const dispatch = center(union(dies)),
    gpu = tiles.filter((tile) => tile.kind === 'gpu');
  const toPhy = (p: Point) =>
    phy.length ? Math.min(...phy.map((segment) => rectDistance(segment, p))) : 0;
  const far = Math.max(1e-6, ...gpu.map((tile) => distance(center(tile), dispatch))),
    farMemory = Math.max(1e-6, ...gpu.map((tile) => toPhy(center(tile))));
  const counters: Partial<Record<TileKind, number>> = {};
  const indexed: Tile[] = tiles.map((tile) => {
    const index = tile.filler ? -1 : (counters[tile.kind] = (counters[tile.kind] ?? -1) + 1),
      middle = center(tile);
    return {
      ...tile,
      index,
      dispatch: clamp(distance(middle, dispatch) / far),
      memory: clamp(toPhy(middle) / farMemory),
    };
  });

  return {
    width,
    height,
    unit,
    substrate,
    dies,
    bridge:
      dies.length > 1
        ? {
            x: dies[0].x + dies[0].w,
            y: dies[0].y + dies[0].h * 0.1,
            w: dies[1].x - dies[0].x - dies[0].w,
            h: dies[0].h * 0.8,
          }
        : null,
    blocks,
    tiles: indexed,
    phy,
    memory,
    traces,
    dispatch,
  };
}
