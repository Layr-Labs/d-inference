import type { Rect } from '../geometry';
import { css, rgba } from '../palette';
import type { Brush } from './brush';
import type { Capacitor } from './substrateLayout';

/** Ceramic chip capacitors: tan bodies, tinned terminals, soft contact shadows. */
export function paintCapacitors(brush: Brush, caps: Capacitor[]) {
  const { ctx, mats, unit, dpr } = brush;
  if (!caps.length) return;
  const bodies = new Path2D();
  for (const cap of caps) bodies.rect(cap.x, cap.y, cap.w, cap.h);
  ctx.save();
  ctx.shadowColor = `rgba(0,0,0,${mats.dark ? 0.75 : 0.5})`;
  ctx.shadowBlur = unit * 0.006 * dpr;
  ctx.shadowOffsetX = unit * 0.0022 * dpr;
  ctx.shadowOffsetY = unit * 0.0042 * dpr;
  ctx.fillStyle = css(mats.ceramicShade);
  ctx.fill(bodies);
  ctx.restore();
  for (const cap of caps) paintCapacitor(brush, cap);
}

/** A gradient across the capacitor's short axis, so it reads as a rounded solid. */
function across(ctx: CanvasRenderingContext2D, cap: Capacitor, stops: [number, string][]) {
  const gradient = cap.vertical
    ? ctx.createLinearGradient(cap.x, 0, cap.x + cap.w, 0)
    : ctx.createLinearGradient(0, cap.y, 0, cap.y + cap.h);
  for (const [stop, color] of stops) gradient.addColorStop(stop, color);
  return gradient;
}

function paintCapacitor(brush: Brush, cap: Capacitor) {
  const { ctx, mats } = brush,
    long = cap.vertical ? cap.h : cap.w,
    end = long * 0.24;
  ctx.fillStyle = across(ctx, cap, [
    [0, css(mats.ceramicShade)],
    [0.32, css(mats.ceramic)],
    [1, css(mats.ceramicShade)],
  ]);
  ctx.fillRect(cap.x, cap.y, cap.w, cap.h);
  const terminals: Rect[] = cap.vertical
    ? [
        { x: cap.x, y: cap.y, w: cap.w, h: end },
        { x: cap.x, y: cap.y + cap.h - end, w: cap.w, h: end },
      ]
    : [
        { x: cap.x, y: cap.y, w: end, h: cap.h },
        { x: cap.x + cap.w - end, y: cap.y, w: end, h: cap.h },
      ];
  ctx.fillStyle = across(ctx, cap, [
    [0, css(mats.terminalShade)],
    [0.3, css(mats.terminal)],
    [0.55, rgba(mats.terminal, 0.92)],
    [1, css(mats.terminalShade)],
  ]);
  for (const t of terminals) ctx.fillRect(t.x, t.y, t.w, t.h);
  ctx.fillStyle = 'rgba(0,0,0,0.28)';
  for (const t of terminals)
    if (cap.vertical) ctx.fillRect(t.x, t === terminals[0] ? t.y + t.h - 0.5 : t.y, t.w, 0.5);
    else ctx.fillRect(t === terminals[0] ? t.x + t.w - 0.5 : t.x, t.y, 0.5, t.h);
}
