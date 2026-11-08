import { clamp } from '../geometry';
import type { Trace } from '../layout';
import { css, rgba } from '../palette';
import { tracePulses } from '../render/activity';
import { along } from '../render/canvas';
import type { RenderFrame } from '../render/types';
import { hot } from './materials';
import type { PhotorealScene } from './scene';

const TAIL = 0.5,
  SEGMENTS = 4;

interface Group {
  write: boolean;
  strength: number;
  streaks: { trace: Trace; at: number }[];
}

/** Adds the stretch [a, b] of a trace (0 = package end, 1 = die end) to the current path. */
function stretch(ctx: CanvasRenderingContext2D, trace: Trace, a: number, b: number) {
  const from = along(trace.from, trace.to, clamp(a)),
    to = along(trace.from, trace.to, clamp(b));
  ctx.moveTo(from.x, from.y);
  ctx.lineTo(to.x, to.y);
}

/**
 * Comet streaks on the substrate traces: reads race from memory to the die with each decode
 * step and KV writes run back. Every pulse of a kind shares one strength, so each tail
 * segment across all traces is a single batched stroke.
 */
export function paintComets(
  ctx: CanvasRenderingContext2D,
  built: PhotorealScene,
  frame: RenderFrame,
) {
  const { workload: w, motion } = frame;
  if (!motion || w.power < 0.01) return;
  const { scene, glow } = built,
    unit = scene.layout.unit,
    groups = new Map<string, Group>();
  for (const trace of scene.layout.traces)
    for (const pulse of tracePulses(trace, frame)) {
      const key = `${pulse.write}:${pulse.strength.toFixed(3)}`;
      let group = groups.get(key);
      if (!group)
        groups.set(key, (group = { write: pulse.write, strength: pulse.strength, streaks: [] }));
      group.streaks.push({ trace, at: pulse.at });
    }
  ctx.lineCap = 'butt';
  for (const { write, strength, streaks } of groups.values()) {
    const color = write ? glow.kv : glow.decode,
      alpha = clamp(strength * w.power),
      back = write ? -TAIL : TAIL;
    ctx.globalAlpha = 1;
    for (let k = 0; k < SEGMENTS; k++) {
      ctx.beginPath();
      for (const { trace, at } of streaks)
        stretch(ctx, trace, at - back * (1 - k / SEGMENTS), at - back * (1 - (k + 1) / SEGMENTS));
      const near = (k + 1) / SEGMENTS;
      if (k >= SEGMENTS - 2) {
        ctx.lineWidth = Math.max(2.4, unit * 0.013);
        ctx.strokeStyle = rgba(color, alpha * 0.22 * near);
        ctx.stroke();
      }
      ctx.lineWidth = Math.max(0.8, unit * 0.0036);
      ctx.strokeStyle = rgba(hot(color, 0.25 * near), alpha * near ** 1.5);
      ctx.stroke();
    }
    ctx.beginPath();
    const r = Math.max(0.7, unit * 0.003);
    for (const { trace, at } of streaks) {
      const head = along(trace.from, trace.to, at);
      ctx.moveTo(head.x + r, head.y);
      ctx.arc(head.x, head.y, r, 0, Math.PI * 2);
    }
    ctx.globalAlpha = alpha * 0.8;
    ctx.fillStyle = css(hot(color, 0.5));
    ctx.fill();
  }
}
