import type { Point, Rect } from '../geometry';
import type { ChipLayout } from '../layout';

/**
 * The layout scaled about the canvas centre. The shared layout pads the package by only a few
 * pixels; shrinking it slightly leaves room inside the canvas for its shadow and glow.
 */
export function fitLayout(layout: ChipLayout, scale: number): ChipLayout {
  const cx = layout.width / 2,
    cy = layout.height / 2;
  const point = <T extends Point>(p: T): T => ({
    ...p,
    x: cx + (p.x - cx) * scale,
    y: cy + (p.y - cy) * scale,
  });
  const rect = <T extends Rect>(r: T): T => ({ ...point(r), w: r.w * scale, h: r.h * scale });
  return {
    ...layout,
    unit: layout.unit * scale,
    substrate: rect(layout.substrate),
    dies: layout.dies.map(rect),
    bridge: layout.bridge && rect(layout.bridge),
    blocks: layout.blocks.map((block) => ({ ...rect(block), body: rect(block.body) })),
    tiles: layout.tiles.map(rect),
    phy: layout.phy.map(rect),
    memory: layout.memory.map((pkg) => ({ ...rect(pkg), cells: pkg.cells.map(rect) })),
    traces: layout.traces.map((trace) => ({
      ...trace,
      from: point(trace.from),
      to: point(trace.to),
    })),
    dispatch: point(layout.dispatch),
  };
}
