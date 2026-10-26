import type { ChipLayout, MemoryPackage } from '../layout';
import { segmentAt, type MemoryMap } from '../memoryMap';
import { roundRect } from '../render/canvas';

export type Ink = (alpha: number) => string;

/** Memory packages with their cell grids, banded by what each share of memory holds. */
export function paintMemoryPackages(
  ctx: CanvasRenderingContext2D,
  layout: ChipLayout,
  memory: MemoryMap,
  ink: Ink,
  dark: boolean,
) {
  for (const pkg of layout.memory) {
    roundRect(ctx, pkg, layout.unit * 0.018);
    ctx.fillStyle = ink(dark ? 0.03 : 0.022);
    ctx.fill();
    ctx.strokeStyle = ink(dark ? 0.17 : 0.18);
    ctx.stroke();
    paintCells(ctx, pkg, memory, ink);
  }
}

function paintCells(
  ctx: CanvasRenderingContext2D,
  pkg: MemoryPackage,
  memory: MemoryMap,
  ink: Ink,
) {
  const n = pkg.cells.length;
  pkg.cells.forEach((cell, i) => {
    const segment = segmentAt(memory, (i + 0.5) / n);
    roundRect(ctx, cell, Math.min(2, Math.min(cell.w, cell.h) * 0.25));
    if (segment.kind === 'reserved') {
      ctx.fillStyle = ink(0.035);
      ctx.fill();
      ctx.strokeStyle = ink(0.06);
      ctx.beginPath();
      ctx.moveTo(cell.x + 1, cell.y + cell.h - 1);
      ctx.lineTo(cell.x + cell.w - 1, cell.y + 1);
      ctx.stroke();
      return;
    }
    ctx.strokeStyle = ink(segment.kind === 'weights' ? 0.13 : 0.085);
    ctx.stroke();
  });
}

/** Substrate traces from each package to the memory interface it faces. */
export function paintTraces(
  ctx: CanvasRenderingContext2D,
  layout: ChipLayout,
  ink: Ink,
  dark: boolean,
) {
  ctx.strokeStyle = ink(dark ? 0.1 : 0.13);
  ctx.beginPath();
  for (const trace of layout.traces) {
    ctx.moveTo(trace.from.x, trace.from.y);
    ctx.lineTo(trace.to.x, trace.to.y);
  }
  ctx.stroke();
  ctx.fillStyle = ink(dark ? 0.22 : 0.24);
  for (const trace of layout.traces) ctx.fillRect(trace.from.x - 0.8, trace.from.y - 0.8, 1.6, 1.6);
}
