import { center, type Rect } from '../geometry';
import { css, rgba } from '../palette';
import { roundRect } from '../render/canvas';
import type { Brush } from './brush';
import { substrateRadius } from './paintSubstrate';

/** [blur, drop, alpha], blur and drop in die-edge units: wide and soft down to tight contact. */
const SHADOWS: Record<'dark' | 'light', [number, number, number][]> = {
  dark: [
    [0.07, 0.026, 0.62],
    [0.014, 0.004, 0.75],
  ],
  light: [
    [0.075, 0.034, 0.22],
    [0.026, 0.011, 0.18],
    [0.008, 0.003, 0.36],
  ],
};

/** What the package sits on: a faint backlight in dark theme, contact and drop shadows in both. */
export function paintStage(brush: Brush, substrate: Rect, width: number, height: number) {
  const { ctx, mats, unit, dpr } = brush,
    margin = Math.max(
      2,
      Math.min(
        substrate.x,
        substrate.y,
        width - substrate.x - substrate.w,
        height - substrate.y - substrate.h,
      ),
    );
  if (mats.dark) {
    const c = center(substrate),
      glow = ctx.createRadialGradient(
        c.x,
        c.y,
        Math.min(substrate.w, substrate.h) * 0.3,
        c.x,
        c.y,
        Math.hypot(substrate.w, substrate.h) * 0.6,
      );
    glow.addColorStop(0, rgba(mats.backlight, 0.22));
    glow.addColorStop(0.55, rgba(mats.backlight, 0.07));
    glow.addColorStop(1, rgba(mats.backlight, 0));
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, width, height);
    rimGlow(brush, substrate, margin);
  }
  for (const [blur, drop, alpha] of SHADOWS[mats.dark ? 'dark' : 'light']) {
    ctx.save();
    ctx.shadowColor = `rgba(0,0,0,${alpha})`;
    ctx.shadowBlur = Math.min(blur * unit, margin * 0.8) * dpr;
    ctx.shadowOffsetY = Math.min(drop * unit, margin * 0.4) * dpr;
    ctx.fillStyle = css(mats.mask);
    roundRect(ctx, substrate, substrateRadius(unit));
    ctx.fill();
    ctx.restore();
  }
  fadeEdges(ctx, width, height, margin);
}

/** Cool rim light spilling past the lit top and left edges; the substrate hides the rest. */
function rimGlow(brush: Brush, substrate: Rect, margin: number) {
  const { ctx, mats, unit, dpr } = brush,
    rim = ctx.createLinearGradient(
      substrate.x,
      substrate.y,
      substrate.x + substrate.w * 0.55,
      substrate.y + substrate.h * 0.8,
    );
  rim.addColorStop(0, rgba(mats.rim, 0.75));
  rim.addColorStop(1, rgba(mats.rim, 0));
  ctx.save();
  ctx.shadowColor = rgba(mats.rim, 0.65);
  ctx.shadowBlur = Math.min(unit * 0.035, margin * 0.7) * dpr;
  ctx.strokeStyle = rim;
  ctx.lineWidth = 2;
  roundRect(ctx, substrate, substrateRadius(unit));
  ctx.stroke();
  ctx.restore();
}

/** Erases toward the canvas edges so glows and shadows never stop in a hard line there. */
function fadeEdges(ctx: CanvasRenderingContext2D, width: number, height: number, band: number) {
  ctx.save();
  ctx.globalCompositeOperation = 'destination-out';
  const edges: [number, number, number, number, Rect][] = [
    [0, 0, band, 0, { x: 0, y: 0, w: band, h: height }],
    [width, 0, width - band, 0, { x: width - band, y: 0, w: band, h: height }],
    [0, 0, 0, band, { x: 0, y: 0, w: width, h: band }],
    [0, height, 0, height - band, { x: 0, y: height - band, w: width, h: band }],
  ];
  for (const [x0, y0, x1, y1, r] of edges) {
    const fade = ctx.createLinearGradient(x0, y0, x1, y1);
    fade.addColorStop(0, 'rgba(0,0,0,1)');
    fade.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = fade;
    ctx.fillRect(r.x, r.y, r.w, r.h);
  }
  ctx.restore();
}
