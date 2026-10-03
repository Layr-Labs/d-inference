import { inset, type Rect } from '../geometry';
import type { MemoryPackage } from '../layout';
import { rgba } from '../palette';
import { interfaceLevel, memoryCell, type CellLight } from '../render/activity';
import type { RenderFrame } from '../render/types';
import { drawSprite, drawSpriteRegion } from './atlas';
import type { PackageLight } from './emissive';
import { drawAround, type LightKit } from './lightKit';
import type { PhotorealScene } from './scene';

/** Inclusive cell indices spanning one rectangle of a row-major grid. */
export interface CellRun {
  first: number;
  last: number;
}

/** Splits cells [from, to) of a row-major grid into at most three rectangles. */
export function cellRuns(from: number, to: number, cols: number): CellRun[] {
  const runs: CellRun[] = [];
  for (let i = from; i < to;) {
    const col = i % cols,
      rows = Math.floor((to - i) / cols);
    const last = col === 0 && rows > 0 ? i + rows * cols - 1 : Math.min(to, i - col + cols) - 1;
    runs.push({ first: i, last });
    i = last + 1;
  }
  return runs;
}

/** The rectangle covered by a run, out to the middle of the gaps around it. */
function runRect(pkg: MemoryPackage, run: CellRun): Rect {
  const a = pkg.cells[run.first],
    b = pkg.cells[run.last],
    gap = pkg.cols > 1 ? pkg.cells[1].x - pkg.cells[0].x - pkg.cells[0].w : 0;
  return inset({ x: a.x, y: a.y, w: b.x + b.w - a.x, h: b.y + b.h - a.y }, -gap / 2);
}

/** KV cells lit from the front of their region up to the fill frontier, which lights partially. */
function paintKv(
  ctx: CanvasRenderingContext2D,
  light: PackageLight,
  cells: CellLight[],
  kit: LightKit,
  alpha: number,
) {
  const { pkg, kinds } = light,
    start = kinds.indexOf('kv');
  if (start < 0) return;
  let full = start;
  while (full < cells.length && kinds[full] === 'kv' && cells[full].kv >= 0.999) full++;
  for (const run of cellRuns(start, full, pkg.cols)) {
    const r = runRect(pkg, run);
    drawSpriteRegion(ctx, light.kv, r, alpha, light.x, light.y);
    drawAround(ctx, kit.haze, r, Math.min(r.w, r.h) * 0.5 + 4, alpha * 0.22);
  }
  const frontier = cells[full];
  if (frontier?.kind === 'kv' && frontier.kv > 0.01)
    drawSpriteRegion(
      ctx,
      light.kv,
      runRect(pkg, { first: full, last: full }),
      frontier.kv * alpha,
      light.x,
      light.y,
    );
}

/**
 * Unified memory glowing through the epoxy: resident weights breathe, KV cells fill from the
 * front of their region and drain, and each decode step sweeps the cells it streams.
 */
export function paintMemory(
  ctx: CanvasRenderingContext2D,
  built: PhotorealScene,
  frame: RenderFrame,
) {
  const { emissive, kit, scene, glow } = built,
    power = frame.workload.power,
    dark = scene.palette.dark,
    bus = interfaceLevel(frame) * power,
    otherAlpha = dark ? 0.1 : 0.08;
  let cells: CellLight[] = [];
  for (const light of emissive.memory) {
    const n = light.pkg.cells.length;
    if (cells.length !== n)
      cells = Array.from({ length: n }, (_, i) => memoryCell(i / n, 1 / n, scene.memory, frame));
    drawSprite(ctx, light.traces, bus * 0.3);
    const resident = cells.find((cell) => cell.kind === 'weights')?.weights ?? 0;
    drawSprite(ctx, light.weights, resident * power * (dark ? 0.4 : 0.36), light.x, light.y);
    paintKv(ctx, light, cells, kit, power * (dark ? 0.95 : 0.9));
    cells.forEach((cell, i) => {
      if (cell.other > 0.01) {
        ctx.globalAlpha = 1;
        ctx.fillStyle = rgba(glow.neutral, cell.other * otherAlpha);
        const r = light.pkg.cells[i];
        ctx.fillRect(r.x, r.y, r.w, r.h);
      }
      if (cell.sweep < 0.02) return;
      const flash = cell.kind === 'kv' ? kit.flash.kv : kit.flash.weights;
      if (flash)
        drawAround(ctx, flash.canvas, light.pkg.cells[i], flash.pad, cell.sweep * power * 0.9);
    });
  }
}
