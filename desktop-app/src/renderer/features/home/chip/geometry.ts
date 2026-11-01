export interface Point {
  x: number;
  y: number;
}
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}
export type Side = 'left' | 'right' | 'top' | 'bottom';
/** How a die laid out in its canonical frame (memory interface on the left/right edges) is placed. */
export type Orientation = 'none' | 'cw' | 'ccw';

export const clamp = (value: number, min = 0, max = 1) => Math.min(max, Math.max(min, value));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
/** Part `index` of `total` split into `parts` near-equal integers, larger parts first. */
export const share = (total: number, parts: number, index: number) =>
  Math.floor(total / parts) + (index < total % parts ? 1 : 0);
export const smoothstep = (edge0: number, edge1: number, x: number) => {
  const t = clamp((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};
export const center = (r: Rect): Point => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });
export function inset(r: Rect, dx: number, dy = dx): Rect {
  const w = Math.max(0, r.w - 2 * dx),
    h = Math.max(0, r.h - 2 * dy);
  return { x: r.x + (r.w - w) / 2, y: r.y + (r.h - h) / 2, w, h };
}
function split(length: number, weights: number[], gap: number) {
  const total = weights.reduce((sum, weight) => sum + weight, 0) || 1,
    usable = Math.max(0, length - gap * (weights.length - 1));
  let offset = 0;
  return weights.map((weight) => {
    const size = (usable * weight) / total,
      span = { offset, size };
    offset += size + gap;
    return span;
  });
}
export function columns(r: Rect, weights: number[], gap: number): Rect[] {
  return split(r.w, weights, gap).map(({ offset, size }) => ({
    x: r.x + offset,
    y: r.y,
    w: size,
    h: r.h,
  }));
}
export function rows(r: Rect, weights: number[], gap: number): Rect[] {
  return split(r.h, weights, gap).map(({ offset, size }) => ({
    x: r.x,
    y: r.y + offset,
    w: r.w,
    h: size,
  }));
}
/** Row-major cells of a cols x rows grid. */
export function grid(r: Rect, cols: number, rowCount: number, gap: number): Rect[] {
  return rows(r, Array(rowCount).fill(1), gap).flatMap((row) =>
    columns(row, Array(cols).fill(1), gap),
  );
}
/** Smallest grid holding `count` cells whose cell shape is closest to `cellAspect` (w / h). */
export function fitGrid(count: number, region: Rect, cellAspect = 1) {
  let best = { cols: count, rows: 1, score: Infinity };
  for (let cols = 1; cols <= count; cols++) {
    const rowCount = Math.ceil(count / cols),
      aspect = region.w / cols / (region.h / rowCount),
      waste = cols * rowCount - count,
      score = Math.abs(Math.log(aspect / cellAspect)) + waste * 0.35;
    if (score < best.score) best = { cols, rows: rowCount, score };
  }
  return { cols: best.cols, rows: best.rows };
}
export function contains(outer: Rect, inner: Rect, epsilon = 1e-6) {
  return (
    inner.x >= outer.x - epsilon &&
    inner.y >= outer.y - epsilon &&
    inner.x + inner.w <= outer.x + outer.w + epsilon &&
    inner.y + inner.h <= outer.y + outer.h + epsilon
  );
}
export function overlaps(a: Rect, b: Rect, epsilon = 1e-6) {
  return (
    a.x < b.x + b.w - epsilon &&
    b.x < a.x + a.w - epsilon &&
    a.y < b.y + b.h - epsilon &&
    b.y < a.y + a.h - epsilon
  );
}
export function union(rects: Rect[]): Rect {
  const x = Math.min(...rects.map((r) => r.x)),
    y = Math.min(...rects.map((r) => r.y));
  return {
    x,
    y,
    w: Math.max(...rects.map((r) => r.x + r.w)) - x,
    h: Math.max(...rects.map((r) => r.y + r.h)) - y,
  };
}
/** Maps a rect from a canonical frame of size `frame` into `target` with a quarter-turn. */
export function orient(r: Rect, frame: { w: number; h: number }, target: Rect, turn: Orientation) {
  if (turn === 'none') return { x: target.x + r.x, y: target.y + r.y, w: r.w, h: r.h };
  if (turn === 'cw')
    return { x: target.x + frame.h - r.y - r.h, y: target.y + r.x, w: r.h, h: r.w };
  return { x: target.x + r.y, y: target.y + frame.w - r.x - r.w, w: r.h, h: r.w };
}
export function orientSide(side: Side, turn: Orientation): Side {
  if (turn === 'none') return side;
  const cw: Record<Side, Side> = { left: 'top', top: 'right', right: 'bottom', bottom: 'left' };
  const ccw: Record<Side, Side> = { left: 'bottom', bottom: 'right', right: 'top', top: 'left' };
  return (turn === 'cw' ? cw : ccw)[side];
}
