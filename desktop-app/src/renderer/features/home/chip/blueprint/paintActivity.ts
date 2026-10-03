import { center, type Rect } from '../geometry';
import type { Trace } from '../layout';
import { css, mix, rgba, type RGB } from '../palette';
import {
  cacheLevel,
  cpuLevel,
  gpuGlow,
  gpuLevel,
  gpuShare,
  interfaceLevel,
  ioPulse,
  memoryCell,
  neuralLevel,
  tracePulses,
} from '../render/activity';
import { along, roundRect, strokeTicks, tileRadius, type GlowCache } from '../render/canvas';
import type { ChipScene, RenderFrame } from '../render/types';

const WHITE: RGB = [255, 255, 255];
interface Look {
  fill: number;
  edge: number;
  halo: number;
  radius?: number;
}

/** The per-frame light pass: only lit parts are drawn over the static schematic. */
export function paintBlueprintActivity(
  ctx: CanvasRenderingContext2D,
  scene: ChipScene,
  frame: RenderFrame,
  glow: GlowCache,
) {
  const { layout, palette, memory } = scene,
    w = frame.workload,
    dark = palette.dark;
  const looks = {
    tile: dark ? { fill: 0.34, edge: 0.95, halo: 0.42 } : { fill: 0.72, edge: 0.9, halo: 0.16 },
    strip: dark ? { fill: 0.28, edge: 0.55, halo: 0.22 } : { fill: 0.55, edge: 0.7, halo: 0.1 },
    resident: dark ? 0.34 : 0.22,
    other: dark ? 0.16 : 0.14,
    kv: dark ? { fill: 0.62, edge: 0.75, halo: 0.18 } : { fill: 0.74, edge: 0.8, halo: 0.08 },
    flash: dark ? { fill: 0.5, edge: 1, halo: 0.5 } : { fill: 0.65, edge: 1, halo: 0.18 },
  };

  const light = (rect: Rect, level: number, color: RGB, look: Look) => {
    if (level < 0.01) return;
    const radius = look.radius ?? tileRadius(rect);
    roundRect(ctx, rect, radius);
    ctx.fillStyle = rgba(color, level * look.fill);
    ctx.fill();
    ctx.lineWidth = 1;
    ctx.strokeStyle = rgba(dark ? mix(color, WHITE, 0.3) : color, level * look.edge);
    ctx.stroke();
    if (look.halo <= 0) return;
    ctx.globalCompositeOperation = dark ? 'lighter' : 'source-over';
    ctx.globalAlpha = Math.min(1, level * look.halo);
    const blur = Math.round(Math.max(4, Math.min(11, Math.min(rect.w, rect.h) * 0.6)));
    glow.draw(ctx, rect, radius, blur, css(color));
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
  };

  const glowScale = gpuGlow(frame),
    share = gpuShare(frame),
    neural = neuralLevel(frame),
    gpuLook = { ...looks.tile, halo: looks.tile.halo * glowScale };
  spill(ctx, scene, (w.prefill * 0.9 + w.decode * 0.35) * glowScale, dark);

  const phyLevel = interfaceLevel(frame);
  for (const segment of layout.phy) {
    light(segment, phyLevel, palette.decode, { ...looks.strip, radius: 1 });
    if (phyLevel < 0.02) continue;
    ctx.lineWidth = 1;
    ctx.strokeStyle = rgba(dark ? mix(palette.decode, WHITE, 0.4) : palette.decode, phyLevel * 0.9);
    strokeTicks(ctx, segment);
  }
  if (layout.bridge)
    light(layout.bridge, Math.max(w.prefill, w.decode * 0.6) * 0.8, palette.prefill, {
      ...looks.strip,
      radius: 1,
    });

  const cache = cacheLevel(frame);
  for (const tile of layout.tiles) {
    if (tile.filler) continue;
    if (tile.kind === 'neural') light(tile, neural, palette.accent, looks.tile);
    else if (tile.kind === 'gpu') {
      const { prefill, decode } = gpuLevel(tile, frame),
        streamed = decode * 0.85,
        level = Math.max(prefill, streamed),
        phase = mix(palette.decode, palette.prefill, prefill / (prefill + streamed + 1e-6));
      light(tile, level, mix(palette.neutral, phase, share), gpuLook);
    } else if (tile.kind === 'slc') light(tile, cache, palette.decode, looks.strip);
    else light(tile, cpuLevel(tile, frame), palette.cpu, looks.tile);
  }

  for (const pkg of layout.memory) {
    const n = pkg.cells.length;
    pkg.cells.forEach((cell, i) => {
      const lit = memoryCell(i / n, 1 / n, memory, frame),
        radius = Math.min(2, Math.min(cell.w, cell.h) * 0.25);
      if (lit.other > 0.01) {
        roundRect(ctx, cell, radius);
        ctx.fillStyle = rgba(palette.neutral, lit.other * looks.other);
        ctx.fill();
      }
      if (lit.kind === 'weights') {
        roundRect(ctx, cell, radius);
        ctx.fillStyle = rgba(
          mix(palette.accent, palette.decode, Math.min(1, lit.model * 0.4)),
          lit.weights * looks.resident,
        );
        ctx.fill();
        light(cell, lit.sweep, palette.decode, { ...looks.flash, radius });
      } else if (lit.kind === 'kv') {
        light(cell, lit.kv * w.power, palette.kv, { ...looks.kv, radius });
        light(cell, lit.sweep, mix(palette.kv, WHITE, 0.45), { ...looks.flash, radius });
      }
    });
  }

  for (const trace of layout.traces)
    for (const pulse of tracePulses(trace, frame))
      comet(
        ctx,
        trace,
        pulse.at,
        pulse.write,
        pulse.strength,
        pulse.write ? palette.kv : palette.decode,
        dark,
      );

  const arrival = ioPulse(frame);
  if (arrival) {
    const [port, end] = layout.io.path,
      at = along(port, end, arrival.at),
      size = Math.max(2.5, layout.unit * 0.012);
    light(
      { x: at.x - size, y: at.y - size, w: size * 2, h: size * 2 },
      arrival.strength,
      palette.accent,
      {
        fill: 1,
        edge: 1,
        halo: 1,
        radius: size,
      },
    );
  }
}

/** Soft light thrown onto the package around the dies while the GPU works (dark theme only). */
function spill(ctx: CanvasRenderingContext2D, scene: ChipScene, level: number, dark: boolean) {
  if (!dark || level < 0.01) return;
  const { layout, palette } = scene,
    middle = center(layout.substrate),
    radius = Math.max(layout.substrate.w, layout.substrate.h) * 0.55;
  const gradient = ctx.createRadialGradient(middle.x, middle.y, 0, middle.x, middle.y, radius);
  gradient.addColorStop(0, rgba(palette.prefill, 0.11 * level));
  gradient.addColorStop(1, rgba(palette.prefill, 0));
  ctx.globalCompositeOperation = 'lighter';
  ctx.fillStyle = gradient;
  ctx.fillRect(middle.x - radius, middle.y - radius, radius * 2, radius * 2);
  ctx.globalCompositeOperation = 'source-over';
}

/** A short bright dash travelling along a trace, fading toward its tail. */
function comet(
  ctx: CanvasRenderingContext2D,
  trace: Trace,
  at: number,
  backwards: boolean,
  strength: number,
  color: RGB,
  dark: boolean,
) {
  const length = 0.3,
    tail = backwards ? Math.min(1, at + length) : Math.max(0, at - length);
  ctx.globalCompositeOperation = dark ? 'lighter' : 'source-over';
  ctx.lineCap = 'round';
  ctx.lineWidth = 1.2;
  for (let i = 0; i < 3; i++) {
    const a = along(trace.from, trace.to, tail + ((at - tail) * i) / 3),
      b = along(trace.from, trace.to, tail + ((at - tail) * (i + 1)) / 3);
    ctx.strokeStyle = rgba(color, strength * (0.2 + i * 0.3));
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.lineTo(b.x, b.y);
    ctx.stroke();
  }
  ctx.globalCompositeOperation = 'source-over';
}
