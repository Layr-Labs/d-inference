import { inset, type Point, type Rect } from '../geometry';
import type { Block, Tile } from '../layout';
import { css, mix, rgba } from '../palette';
import { noise } from '../random';
import { longAxis, snap, texture, type Brush } from './brush';
import { bandParts, tileParts, type Part, type PartRole } from './dieParts';
import type { Silicon } from './materials';
import type { Textures } from './textures';

interface Finish {
  color: keyof Silicon;
  tile: (tex: Textures, axis: 'x' | 'y') => HTMLCanvasElement;
  alpha: number;
}
const FINISH: Record<PartRole, Finish> = {
  alu: { color: 'alu', tile: (t, axis) => t.lanes[axis], alpha: 0.5 },
  reg: { color: 'reg', tile: (t, axis) => t.sram[axis], alpha: 0.5 },
  cache: { color: 'cache', tile: (t, axis) => t.sram[axis], alpha: 0.45 },
  sram: { color: 'sram', tile: (t, axis) => t.sram[axis], alpha: 0.5 },
  logic: { color: 'logic', tile: (t) => t.logic, alpha: 0.5 },
  spine: { color: 'spine', tile: (t) => t.grain, alpha: 0.25 },
  mac: { color: 'mac', tile: (t) => t.mac, alpha: 0.5 },
};
const WHITE = [255, 255, 255] as const,
  BLACK = [0, 0, 0] as const;

export function paintPart(brush: Brush, part: Part, anchor?: Point) {
  const finish = FINISH[part.role],
    { ctx, mats, tex } = brush;
  ctx.fillStyle = css(mats.silicon[finish.color]);
  ctx.fillRect(part.x, part.y, part.w, part.h);
  texture(brush, part, finish.tile(tex, longAxis(part)), finish.alpha, undefined, anchor);
}

/** A hairline just inside `r`, aligned to device pixels. */
function outline(brush: Brush, r: Rect, color: string) {
  const { ctx, dpr } = brush,
    line = 1 / dpr;
  ctx.lineWidth = line;
  ctx.strokeStyle = color;
  ctx.strokeRect(r.x + line / 2, r.y + line / 2, r.w - line, r.h - line);
}

/** Lightens or darkens `r` by `amount` in [-1, 1]. */
function shade(brush: Brush, r: Rect, amount: number) {
  if (Math.abs(amount) < 0.002) return;
  brush.ctx.fillStyle = rgba(amount > 0 ? WHITE : BLACK, Math.abs(amount));
  brush.ctx.fillRect(r.x, r.y, r.w, r.h);
}

export function paintTile(brush: Brush, tile: Tile) {
  const { ctx, mats, tex, dpr } = brush,
    anchor = { x: snap(tile.x, dpr), y: snap(tile.y, dpr) };
  ctx.fillStyle = css(mix(mats.silicon.logic, mats.silicon.fabric, 0.45));
  ctx.fillRect(tile.x, tile.y, tile.w, tile.h);
  texture(brush, tile, tex.logic, 0.3);
  for (const part of tileParts(tile)) paintPart(brush, part, anchor);
  const variation = (noise(tile.x * 0.173 + tile.y * 0.311 + tile.die * 7.7) - 0.5) * 0.07;
  // Binned cores read slightly darker than powered logic.
  const dim = tile.filler ? 0.22 : 0;
  shade(brush, tile, variation - dim);
  outline(brush, tile, 'rgba(0,0,0,0.3)');
}

export function paintBlock(brush: Brush, block: Block) {
  if (block.kind === 'interface') return paintPhy(brush, block);
  for (const part of bandParts(block)) paintPart(brush, part);
  shade(brush, block.body, -0.1);
}

/** Memory interface strip: repeating I/O cells with a column of bump pads toward the package. */
function paintPhy(brush: Brush, block: Block) {
  const { ctx, mats, tex } = brush,
    axis = longAxis(block);
  ctx.fillStyle = css(mats.silicon.phy);
  ctx.fillRect(block.x, block.y, block.w, block.h);
  texture(brush, block, tex.io[axis], 0.5);
  const short = Math.min(block.w, block.h),
    size = short * 0.26,
    pitch = size * 2.3,
    long = axis === 'x' ? block.w : block.h,
    outer = block.side === 'left' || block.side === 'top';
  const across = (axis === 'x' ? block.y : block.x) + (outer ? short * 0.12 : short * 0.88 - size);
  ctx.fillStyle = rgba(mats.silicon.seal, mats.dark ? 0.24 : 0.3);
  for (let at = (long % pitch) / 2 + (pitch - size) / 2; at + size <= long; at += pitch) {
    const start = (axis === 'x' ? block.x : block.y) + at;
    if (axis === 'x') ctx.fillRect(start, across, size, size);
    else ctx.fillRect(across, start, size, size);
  }
  outline(brush, inset(block, -0.5), 'rgba(0,0,0,0.45)');
}
