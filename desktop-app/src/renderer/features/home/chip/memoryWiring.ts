import { clamp, grid, inset, type Point, type Rect, type Side } from './geometry';
import type { Block, MemoryPackage, PhySegment, Trace } from './layout';

/**
 * Connects each memory package to the memory interface strip it faces: the strip segment
 * that serves it, the substrate traces between them, and the package's cell grid.
 */
export function wireMemory(
  packages: { rect: Rect; side: Side }[],
  interfaces: Block[],
  unit: number,
) {
  const phy: PhySegment[] = [],
    traces: Trace[] = [];
  const memory: MemoryPackage[] = packages.map(({ rect, side }, index) => {
    const vertical = side === 'top' || side === 'bottom';
    const facing = interfaces.find(
      (block) =>
        block.side === side &&
        (vertical
          ? Math.min(block.x + block.w, rect.x + rect.w) > Math.max(block.x, rect.x)
          : Math.min(block.y + block.h, rect.y + rect.h) > Math.max(block.y, rect.y)),
    );
    if (facing) {
      const start = vertical ? Math.max(facing.x, rect.x) : Math.max(facing.y, rect.y),
        end = vertical
          ? Math.min(facing.x + facing.w, rect.x + rect.w)
          : Math.min(facing.y + facing.h, rect.y + rect.h);
      phy.push({
        ...(vertical
          ? { x: start, y: facing.y, w: end - start, h: facing.h }
          : { x: facing.x, y: start, w: facing.w, h: end - start }),
        side,
        die: facing.die,
        package: index,
      });
      const lanes = Math.round(clamp((end - start) / (unit * 0.034), 4, 12));
      for (let lane = 0; lane < lanes; lane++) {
        const t = start + (end - start) * (0.12 + (0.76 * (lane + 0.5)) / lanes);
        const [from, to] = traceEnds(rect, facing, side, t);
        traces.push({ from, to, package: index, lane });
      }
    }
    const inner = inset(rect, unit * 0.035),
      cols = Math.max(2, Math.round(inner.w / (unit * 0.06))),
      rows = Math.max(2, Math.round(inner.h / (unit * 0.04)));
    return {
      ...rect,
      index,
      side,
      die: facing?.die ?? 0,
      cols,
      rows,
      cells: grid(inner, cols, rows, unit * 0.009),
    };
  });
  return { memory, phy, traces };
}

/** Trace endpoints: the package edge facing the die, and the strip's outer edge. */
function traceEnds(pkg: Rect, strip: Rect, side: Side, t: number): [Point, Point] {
  switch (side) {
    case 'right':
      return [
        { x: pkg.x, y: t },
        { x: strip.x + strip.w, y: t },
      ];
    case 'left':
      return [
        { x: pkg.x + pkg.w, y: t },
        { x: strip.x, y: t },
      ];
    case 'top':
      return [
        { x: t, y: pkg.y + pkg.h },
        { x: t, y: strip.y },
      ];
    case 'bottom':
      return [
        { x: t, y: pkg.y },
        { x: t, y: strip.y + strip.h },
      ];
  }
}
