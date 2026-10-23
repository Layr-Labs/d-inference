import { contains, inset, overlaps, union, type Point, type Rect, type Side } from '../geometry';
import type { ChipLayout } from '../layout';
import { seeded } from '../random';

export interface Capacitor extends Rect {
  /** Terminals at the top and bottom rather than at the left and right. */
  vertical: boolean;
}

/** 0201-class decoupling capacitors, in die-edge units. */
const CAP = { length: 0.032, width: 0.017, pitch: 0.031, standoff: 0.02 };
const SIDES: Side[] = ['top', 'bottom', 'left', 'right'];
const inside = (r: Rect, p: Point) => p.x > r.x && p.x < r.x + r.w && p.y > r.y && p.y < r.y + r.h;

/** Whether `other` lies beyond `side` of `r` and overlaps it along that edge. */
function beyond(r: Rect, other: Rect, side: Side) {
  const spanX = Math.min(r.x + r.w, other.x + other.w) > Math.max(r.x, other.x),
    spanY = Math.min(r.y + r.h, other.y + other.h) > Math.max(r.y, other.y);
  if (side === 'left') return spanY && other.x + other.w <= r.x + 1e-6;
  if (side === 'right') return spanY && other.x >= r.x + r.w - 1e-6;
  if (side === 'top') return spanX && other.y + other.h <= r.y + 1e-6;
  return spanX && other.y >= r.y + r.h - 1e-6;
}

/** Capacitors centred along a→b at a regular pitch, standing across the run. */
function row(a: Point, b: Point, unit: number, spread = 1): Capacitor[] {
  const length = CAP.length * unit,
    width = CAP.width * unit,
    pitch = CAP.pitch * unit * spread,
    span = Math.hypot(b.x - a.x, b.y - a.y),
    count = Math.floor(span / pitch) + 1,
    vertical = Math.abs(b.x - a.x) >= Math.abs(b.y - a.y);
  return Array.from({ length: count }, (_, i) => {
    const t = span > 0 ? ((span - (count - 1) * pitch) / 2 + i * pitch) / span : 0.5,
      x = a.x + (b.x - a.x) * t,
      y = a.y + (b.y - a.y) * t;
    return vertical
      ? { x: x - width / 2, y: y - length / 2, w: width, h: length, vertical }
      : { x: x - length / 2, y: y - width / 2, w: length, h: width, vertical };
  });
}

/** The run just beyond `side` of `r`, covering the middle `cover` of that edge. */
function beside(r: Rect, side: Side, unit: number, cover: number): [Point, Point] {
  const reach = (CAP.standoff + CAP.length / 2) * unit,
    dx = (r.w * (1 - cover)) / 2,
    dy = (r.h * (1 - cover)) / 2;
  if (side === 'top')
    return [
      { x: r.x + dx, y: r.y - reach },
      { x: r.x + r.w - dx, y: r.y - reach },
    ];
  if (side === 'bottom')
    return [
      { x: r.x + dx, y: r.y + r.h + reach },
      { x: r.x + r.w - dx, y: r.y + r.h + reach },
    ];
  const x = side === 'left' ? r.x - reach : r.x + r.w + reach;
  return [
    { x, y: r.y + dy },
    { x, y: r.y + r.h - dy },
  ];
}

/** Rows along the midline of each gap between neighbouring packages on the same edge. */
function gapRows(layout: ChipLayout, unit: number) {
  return SIDES.flatMap((side) => {
    const stacked = side === 'left' || side === 'right',
      line = layout.memory
        .filter((pkg) => pkg.side === side)
        .sort((a, b) => (stacked ? a.y - b.y : a.x - b.x));
    return line.slice(1).flatMap((b, i) => {
      const a = line[i],
        gap = stacked ? b.y - a.y - a.h : b.x - a.x - a.w;
      if (gap < CAP.length * unit * 1.3) return [];
      const mid = stacked ? a.y + a.h + gap / 2 : a.x + a.w + gap / 2;
      return stacked
        ? row({ x: a.x + a.w * 0.1, y: mid }, { x: a.x + a.w * 0.9, y: mid }, unit)
        : row({ x: mid, y: a.y + a.h * 0.1 }, { x: mid, y: a.y + a.h * 0.9 }, unit);
    });
  });
}

/** Decoupling capacitors on die edges free of memory, between packages and outside them. */
export function capacitorLayout(layout: ChipLayout): Capacitor[] {
  const { unit } = layout,
    caps: Capacitor[] = [];
  for (const die of layout.dies)
    for (const side of SIDES) {
      const blocked =
        layout.memory.some((pkg) => beyond(die, pkg, side)) ||
        layout.dies.some((other) => other !== die && beyond(die, other, side));
      if (!blocked) caps.push(...row(...beside(die, side, unit, 0.86), unit));
    }
  caps.push(...gapRows(layout, unit));
  for (const pkg of layout.memory)
    caps.push(...row(...beside(pkg, pkg.side, unit, 0.8), unit, 1.7));
  const room = inset(layout.substrate, unit * 0.045),
    keepOut = [
      ...layout.dies.map((die) => inset(die, -unit * 0.01)),
      ...layout.memory.map((pkg) => inset(pkg, -unit * 0.006)),
      ...(layout.bridge ? [layout.bridge] : []),
    ];
  return caps.filter((cap) => contains(room, cap) && !keepOut.some((r) => overlaps(r, cap)));
}

/** Sparse vias in open solder mask, clear of parts and trace fields; seeded, so stable. */
export function viaLayout(layout: ChipLayout, caps: Rect[]): Point[] {
  const { substrate, unit } = layout,
    step = unit * 0.034,
    random = seeded(53),
    room = inset(substrate, unit * 0.05);
  const fields = layout.memory.flatMap((pkg) => {
    const ends = layout.traces
      .filter((trace) => trace.package === pkg.index)
      .flatMap(({ from, to }) => [from, to])
      .map((p) => ({ ...p, w: 0, h: 0 }));
    return ends.length ? [inset(union(ends), -unit * 0.016)] : [];
  });
  const keepOut = [
    ...layout.dies.map((die) => inset(die, -unit * 0.03)),
    ...layout.memory.map((pkg) => inset(pkg, -unit * 0.022)),
    ...caps.map((cap) => inset(cap, -unit * 0.01)),
    ...fields,
  ];
  const vias: Point[] = [];
  for (let r = 0; r * step < room.h; r++)
    for (let c = 0; c * step < room.w; c++) {
      const p = { x: room.x + (c + random()) * step, y: room.y + (r + random()) * step };
      if (random() > 0.16 || !inside(room, p) || keepOut.some((k) => inside(k, p))) continue;
      vias.push(p);
    }
  return vias;
}
