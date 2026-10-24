import { center, inset, union, type Rect } from '../geometry';
import type { Trace } from '../layout';
import { css, rgba, type RGB } from '../palette';
import { noise } from '../random';
import { longAxis, texture, type Brush } from './brush';
import type { Part, PartRole } from './dieParts';
import { blurredFill, rectPath } from './glow';
import { hot } from './materials';
import type { Textures } from './textures';

/** Halo radius for a lit region, in CSS pixels. */
export const haloOf = (r: Rect, scale = 0.36, max = 9) =>
  Math.max(2.5, Math.min(max, Math.min(r.w, r.h) * scale));

interface PartGlow {
  alpha: number;
  mask?: (glow: Textures['glow'], axis: 'x' | 'y') => HTMLCanvasElement;
  hot?: number;
}
/** How brightly each part emits: ALU lanes run hottest, spines and MAC arrays barely glow. */
const PART_GLOW: Record<PartRole, PartGlow> = {
  alu: { alpha: 0.08, mask: (g, axis) => g.lanes[axis], hot: 0.46 },
  reg: { alpha: 0.06, mask: (g, axis) => g.sram[axis], hot: 0.26 },
  cache: { alpha: 0.05, mask: (g, axis) => g.sram[axis], hot: 0.2 },
  sram: { alpha: 0.07, mask: (g, axis) => g.sram[axis], hot: 0.3 },
  logic: { alpha: 0.05, mask: (g) => g.logic, hot: 0.26 },
  spine: { alpha: 0.02 },
  mac: { alpha: 0.04 },
};
/** Busier and quieter arrays within one core, fixed per part and variant. */
const activity = (part: Rect, seed: number) =>
  0.7 + 0.6 * noise(part.x * 0.71 + part.y * 1.37 + seed * 17.3);

/**
 * A lit tile or engine: a halo, a wash falling off from the middle, every part lit through
 * its own texture, and a white-hot core over the busiest logic.
 */
export function paintPartsGlow(
  brush: Brush,
  area: Rect,
  parts: Part[],
  color: RGB,
  halo: number,
  haloAlpha: number,
  seed = 0,
) {
  const { ctx, tex } = brush,
    bright = css(hot(color, 0.18)),
    middle = center(area);
  blurredFill(ctx, rectPath(area), halo, rgba(color, haloAlpha));
  const wash = ctx.createRadialGradient(
    middle.x,
    middle.y,
    0,
    middle.x,
    middle.y,
    Math.hypot(area.w, area.h) / 2,
  );
  wash.addColorStop(0, rgba(color, 0.15));
  wash.addColorStop(1, rgba(color, 0.03));
  ctx.fillStyle = wash;
  ctx.fillRect(area.x, area.y, area.w, area.h);
  for (const part of parts) {
    const glow = PART_GLOW[part.role],
      busy = activity(part, seed);
    ctx.fillStyle = rgba(color, glow.alpha * busy);
    ctx.fillRect(part.x, part.y, part.w, part.h);
    if (glow.mask && glow.hot)
      texture(brush, part, glow.mask(tex.glow, longAxis(part)), glow.hot * busy, bright);
  }
  const engines = parts.filter((part) => part.role === 'alu' || part.role === 'logic');
  if (!engines.length) return;
  const core = union(engines),
    short = Math.min(core.w, core.h);
  blurredFill(ctx, rectPath(inset(core, short * 0.22)), short * 0.4, rgba(hot(color, 0.45), 0.2));
}

/** A lit strip of repeating cells (memory interface, die bridge). */
export function paintStripGlow(
  brush: Brush,
  r: Rect,
  color: RGB,
  mask: HTMLCanvasElement,
  haloAlpha: number,
) {
  const { ctx } = brush;
  blurredFill(ctx, rectPath(r), haloOf(r, 1.1, 7), rgba(color, haloAlpha));
  ctx.fillStyle = rgba(color, 0.1);
  ctx.fillRect(r.x, r.y, r.w, r.h);
  texture(brush, r, mask, 0.46, css(hot(color, 0.3)));
}

/** Cells seen through black epoxy: light diffused by the mold compound, hotter at the middle. */
export function paintCellsGlow(brush: Brush, cells: Rect[], color: RGB, halo: boolean) {
  const { ctx, unit, tex } = brush;
  if (!cells.length) return;
  const body = new Path2D(),
    core = new Path2D();
  for (const cell of cells) {
    const short = Math.min(cell.w, cell.h);
    rectPath(inset(cell, short * 0.08), short * 0.12, body);
    rectPath(inset(cell, short * 0.3), short * 0.1, core);
  }
  if (halo) blurredFill(ctx, body, unit * 0.022, rgba(color, 0.34));
  blurredFill(ctx, body, Math.max(1, unit * 0.005), rgba(color, 0.7));
  blurredFill(ctx, core, Math.max(1.2, unit * 0.009), rgba(hot(color, 0.5), 0.3));
  ctx.save();
  ctx.clip(body);
  texture(brush, union(cells), tex.glow.dram[longAxis(cells[0])], 0.1, css(hot(color, 0.7)));
  ctx.restore();
}

/** Substrate traces carrying a read burst: a blurred bloom under a bright core line. */
export function paintTracesGlow(brush: Brush, traces: Trace[], color: RGB) {
  const { ctx, unit, dpr } = brush,
    path = new Path2D();
  for (const { from, to } of traces) {
    path.moveTo(from.x, from.y);
    path.lineTo(to.x, to.y);
  }
  ctx.lineCap = 'round';
  ctx.save();
  ctx.shadowColor = rgba(color, 0.9);
  ctx.shadowBlur = unit * 0.014 * dpr;
  ctx.strokeStyle = rgba(color, 0.45);
  ctx.lineWidth = Math.max(1, unit * 0.005);
  ctx.stroke(path);
  ctx.restore();
  ctx.strokeStyle = rgba(hot(color), 0.75);
  ctx.lineWidth = Math.max(0.5, unit * 0.0022);
  ctx.stroke(path);
}

export function traceBounds(traces: Trace[]): Rect {
  return union(traces.flatMap(({ from, to }) => [from, to]).map((p) => ({ ...p, w: 0, h: 0 })));
}
