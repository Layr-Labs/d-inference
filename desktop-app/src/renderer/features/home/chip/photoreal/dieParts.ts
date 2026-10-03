import { columns, inset, rows, type Rect } from '../geometry';
import type { Block, Tile } from '../layout';
import { noise } from '../random';

export type PartRole = 'alu' | 'reg' | 'cache' | 'sram' | 'logic' | 'spine' | 'mac';
/** A functional region inside a tile or block, shared by the die texture and its emissive map. */
export interface Part extends Rect {
  role: PartRole;
}

/** Splits along the rect's long axis. */
const along = (r: Rect, weights: number[], gap: number) =>
  (r.w >= r.h ? columns : rows)(r, weights, gap);
/** Splits across the rect's long axis. */
const across = (r: Rect, weights: number[], gap: number) =>
  (r.w >= r.h ? rows : columns)(r, weights, gap);
const as =
  (role: PartRole) =>
  (r: Rect): Part => ({ ...r, role });
function frame(r: Rect, margin: number, gap: number) {
  const short = Math.min(r.w, r.h);
  return { body: inset(r, Math.max(0.4, short * margin)), gap: Math.max(0.3, short * gap) };
}

/** Four ALU quadrants halved by a spine, register files between them, texture and control. */
function gpuCore(tile: Rect): Part[] {
  const { body, gap } = frame(tile, 0.07, 0.04);
  const [exec, side] = along(body, [0.74, 0.26], gap);
  const bands = along(exec, [1, 0.18, 1, 0.18, 1, 0.18, 1], 0).flatMap((band, i): Part[] => {
    if (i % 2) return [{ ...band, role: 'reg' }];
    const [a, spine, b] = along(band, [1, 0.14, 1], 0);
    return [as('alu')(a), as('spine')(spine), as('alu')(b)];
  });
  const [texture, control] = along(side, [0.62, 0.38], gap);
  return [...bands, as('cache')(texture), as('logic')(control)];
}

/** L1 caches at one end, execution units beside the register file, front end at the other. */
function cpuCore(tile: Rect, efficiency: boolean): Part[] {
  const { body, gap } = frame(tile, 0.06, 0.045);
  const [caches, exec, front] = along(
    body,
    efficiency ? [0.3, 0.45, 0.25] : [0.24, 0.52, 0.24],
    gap,
  );
  const [units, registers] = along(exec, [0.64, 0.36], gap);
  return [
    ...along(caches, [1, 1], gap).map(as('cache')),
    as('logic')(units),
    as('reg')(registers),
    as('logic')(front),
  ];
}

/** Two rows of SRAM banks either side of a control spine. */
function sramArray(tile: Rect): Part[] {
  const { body, gap } = frame(tile, 0.05, 0.03),
    [a, spine, b] = across(body, [1, 0.12, 1], 0);
  const banks = Math.max(
    1,
    Math.min(6, Math.round((Math.max(a.w, a.h) / Math.min(a.w, a.h)) * 0.7)),
  );
  return [
    ...[a, b].flatMap((half) => along(half, Array(banks).fill(1), gap).map(as('sram'))),
    as('spine')(spine),
  ];
}

function neuralCore(tile: Rect): Part[] {
  const { body, gap } = frame(tile, 0.08, 0.05),
    [mac, buffer] = along(body, [0.74, 0.26], gap);
  return [as('mac')(mac), as('cache')(buffer)];
}

export function tileParts(tile: Tile): Part[] {
  switch (tile.kind) {
    case 'gpu':
      return gpuCore(tile);
    case 'super':
    case 'performance':
    case 'efficiency':
      return cpuCore(tile, tile.kind === 'efficiency');
    case 'neural':
      return neuralCore(tile);
    default:
      return sramArray(tile);
  }
}

const blockSeed = (block: Block) => block.x * 0.137 + block.y * 0.291 + block.die * 5.3;

/** Engines without counted tiles: a few strips of SRAM buffers and control logic. */
export function engineParts(block: Block): Part[] {
  const { body, gap } = frame(block, 0.08, 0.05),
    seed = blockSeed(block);
  const strips = along(
    body,
    [0, 1, 2].map((i) => 0.6 + noise(seed + i)),
    gap,
  );
  return strips.flatMap((strip, i) => {
    const [a, b] = across(strip, [0.5 + 0.35 * noise(seed + i * 3.1), 0.5], gap);
    return [as(noise(seed + i * 5.7) > 0.4 ? 'cache' : 'logic')(a), as('logic')(b)];
  });
}

/** The label band of a block (its widest margin outside the body), or null when unbanded. */
function bandOf(block: Block): Rect | null {
  const { body } = block,
    top = body.y - block.y,
    bottom = block.y + block.h - body.y - body.h,
    left = body.x - block.x,
    right = block.x + block.w - body.x - body.w,
    widest = Math.max(top, bottom, left, right);
  if (widest < Math.min(top, bottom, left, right) * 2 + 1) return null;
  if (widest === top) return { x: block.x, y: block.y, w: block.w, h: top };
  if (widest === bottom) return { x: block.x, y: body.y + body.h, w: block.w, h: bottom };
  if (widest === left) return { x: block.x, y: block.y, w: left, h: block.h };
  return { x: body.x + body.w, y: block.y, w: right, h: block.h };
}

/** Clock, power-management and interconnect macros scattered along a block's label band. */
export function bandParts(block: Block): Part[] {
  const band = bandOf(block);
  if (!band) return [];
  const seed = blockSeed(block) + 17,
    lane = inset(band, Math.min(band.w, band.h) * 0.22),
    count = Math.max(2, Math.round(Math.max(lane.w, lane.h) / Math.min(lane.w, lane.h) / 2.2));
  const slots = along(
    lane,
    Array.from({ length: count }, (_, i) => 0.5 + noise(seed + i)),
    2,
  );
  return slots
    .filter((_, i) => noise(seed + i * 2.3) > 0.35)
    .map((slot, i) => as(noise(seed + i * 4.1) > 0.5 ? 'cache' : 'logic')(slot));
}
