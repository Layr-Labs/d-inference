import type { Point, Rect } from '../geometry';
import type { MemoryPackage, Tile } from '../layout';
import { segmentAt, type MemoryKind, type MemoryMap } from '../memoryMap';
import type { RGB } from '../palette';
import { noise } from '../random';
import type { ChipScene } from '../render/types';
import { createAtlas, type Sprite } from './atlas';
import { createBrush, longAxis, snap, type Brush } from './brush';
import { engineParts, tileParts } from './dieParts';
import {
  haloOf,
  paintCellsGlow,
  paintPartsGlow,
  paintStripGlow,
  paintTracesGlow,
  traceBounds,
} from './emissivePaint';
import type { Glow, Materials } from './materials';
import type { Textures } from './textures';

/** Shared sprites are baked around a local origin; `x`, `y` is where it lands for this part. */
export interface GpuLight extends Point {
  tile: Tile;
  prefill: Sprite | null;
  decode: Sprite | null;
  /** GPU work that is not Darkbloom's. */
  neutral: Sprite | null;
}
export interface TileLight extends Point {
  tile: Tile;
  sprite: Sprite | null;
}
export interface PackageLight extends Point {
  pkg: MemoryPackage;
  /** What each cell holds; the split repeats in every package because memory is interleaved. */
  kinds: MemoryKind[];
  weights: Sprite | null;
  kv: Sprite | null;
  traces: Sprite | null;
}
/** Pre-tinted light for every part that can glow, each drawn at its activity level per frame. */
export interface Emissive {
  gpu: GpuLight[];
  cpu: TileLight[];
  slc: TileLight[];
  neural: TileLight[];
  phy: (Sprite | null)[];
  bridge: Sprite | null;
  io: Sprite | null;
  memory: PackageLight[];
  atlas: HTMLCanvasElement | null;
}

/** Light patterns per tile shape, so identical cores don't all glow alike. */
const VARIANTS = 3;
const cellKinds = (count: number, memory: MemoryMap) =>
  Array.from({ length: count }, (_, i) => segmentAt(memory, (i + 0.5) / count).kind);

export function buildEmissive(
  scene: ChipScene,
  mats: Materials,
  glow: Glow,
  tex: Textures,
): Emissive {
  const { layout, memory, dpr } = scene,
    { unit } = layout,
    atlas = createAtlas(dpr),
    haloAlpha = mats.dark ? 0.17 : 0.12,
    shared = new Map<string, number>(),
    origin = (r: Rect): Point => ({ x: snap(r.x, dpr), y: snap(r.y, dpr) });
  let brush: Brush | null = null;
  const queue = (bounds: Rect, pad: number, paint: (brush: Brush) => void) =>
    atlas.add(bounds, pad, (ctx) => paint((brush ??= createBrush(ctx, dpr, unit, mats, tex))));
  /** Identical tiles share a slot per shape, variant and colour, baked with the tile at 0, 0. */
  const tileSlot = (tile: Tile, color: RGB, scale: number, max: number) => {
    const variant = Math.floor(noise(tile.index * 3.7 + tile.die * 11.1) * VARIANTS),
      shape = `${Math.round(tile.w * dpr)}x${Math.round(tile.h * dpr)}`,
      key = `${tile.kind}:${shape}:${variant}:${color}`;
    let slot = shared.get(key);
    if (slot === undefined) {
      const local = { ...tile, x: 0, y: 0 },
        halo = haloOf(local, scale, max);
      slot = queue(local, halo * 1.5, (b) =>
        paintPartsGlow(b, local, tileParts(local), color, halo, haloAlpha, variant),
      );
      shared.set(key, slot);
    }
    return slot;
  };

  const gpu: { tile: Tile; prefill: number; decode: number; neutral: number }[] = [],
    cpu: { tile: Tile; slot: number }[] = [],
    slc: { tile: Tile; slot: number }[] = [],
    neural: { tile: Tile; slot: number }[] = [];
  for (const tile of layout.tiles) {
    if (tile.filler) continue;
    if (tile.kind === 'neural') neural.push({ tile, slot: tileSlot(tile, glow.accent, 0.3, 6) });
    else if (tile.kind === 'gpu')
      gpu.push({
        tile,
        prefill: tileSlot(tile, glow.prefill, 0.36, 9),
        decode: tileSlot(tile, glow.decode, 0.36, 9),
        neutral: tileSlot(tile, glow.neutral, 0.36, 9),
      });
    else if (tile.kind === 'slc') slc.push({ tile, slot: tileSlot(tile, glow.decode, 0.3, 6) });
    else cpu.push({ tile, slot: tileSlot(tile, glow.cpu, 0.42, 7) });
  }
  const phy = layout.phy.map((segment) =>
    queue(segment, 8, (b) =>
      paintStripGlow(b, segment, glow.decode, b.tex.glow.io[longAxis(segment)], haloAlpha),
    ),
  );
  const seam = layout.bridge,
    bridge = seam
      ? queue(seam, 8, (b) =>
          paintStripGlow(b, seam, glow.prefill, b.tex.glow.lanes[longAxis(seam)], haloAlpha),
        )
      : -1;
  const ioBlock = layout.blocks.find((block) => block.kind === 'io' && block.die === 0),
    io = ioBlock
      ? queue(ioBlock, 12, (b) =>
          paintPartsGlow(b, ioBlock, engineParts(ioBlock), glow.accent, 6, haloAlpha),
        )
      : -1;

  const regions = new Map<string, { weights: number; kv: number }>();
  const packages = layout.memory.map((pkg) => {
    const kinds = cellKinds(pkg.cells.length, memory),
      at = origin(pkg),
      key = `${Math.round(pkg.w * dpr)}x${Math.round(pkg.h * dpr)}:${pkg.cols}x${pkg.rows}`;
    let slots = regions.get(key);
    if (!slots) {
      const local = { x: 0, y: 0, w: pkg.w, h: pkg.h },
        cells = (kind: MemoryKind) =>
          pkg.cells
            .filter((_, i) => kinds[i] === kind)
            .map((cell) => ({ ...cell, x: cell.x - at.x, y: cell.y - at.y })),
        weights = cells('weights'),
        kv = cells('kv');
      slots = {
        weights: weights.length
          ? queue(local, unit * 0.034, (b) => paintCellsGlow(b, weights, glow.accent, true))
          : -1,
        kv: kv.length ? queue(local, 2, (b) => paintCellsGlow(b, kv, glow.kv, false)) : -1,
      };
      regions.set(key, slots);
    }
    const traces = layout.traces.filter((trace) => trace.package === pkg.index);
    return {
      pkg,
      kinds,
      at,
      ...slots,
      traces: traces.length
        ? queue(traceBounds(traces), unit * 0.03, (b) => paintTracesGlow(b, traces, glow.decode))
        : -1,
    };
  });

  const sprites = atlas.build(),
    sprite = (slot: number) => (slot >= 0 ? (sprites[slot] ?? null) : null),
    tileLight = ({ tile, slot }: { tile: Tile; slot: number }): TileLight => ({
      tile,
      ...origin(tile),
      sprite: sprite(slot),
    });
  return {
    gpu: gpu.map(({ tile, prefill, decode, neutral }) => ({
      tile,
      ...origin(tile),
      prefill: sprite(prefill),
      decode: sprite(decode),
      neutral: sprite(neutral),
    })),
    cpu: cpu.map(tileLight),
    slc: slc.map(tileLight),
    neural: neural.map(tileLight),
    phy: phy.map(sprite),
    bridge: sprite(bridge),
    io: sprite(io),
    memory: packages.map(({ pkg, kinds, at, weights, kv, traces }) => ({
      pkg,
      kinds,
      ...at,
      weights: sprite(weights),
      kv: sprite(kv),
      traces: sprite(traces),
    })),
    atlas: sprites[0]?.source ?? null,
  };
}
