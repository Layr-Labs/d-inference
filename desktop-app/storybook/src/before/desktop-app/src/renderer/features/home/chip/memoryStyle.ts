import type { Rect } from './geometry';
import { css, rgba, type RGB } from './palette';

const COLORS: RGB[] = [
  [108, 160, 255],
  [67, 206, 168],
  [245, 176, 76],
  [202, 130, 246],
];
export const modelColor = (index: number): RGB => COLORS[Math.max(0, index) % COLORS.length];
export const modelCSS = (index: number) => css(modelColor(index));

/** Crosses mark memory belonging to other apps and macOS in both canvas variants. */
export function crossMemory(ctx: CanvasRenderingContext2D, r: Rect, color: RGB, intensity: number) {
  ctx.fillStyle = rgba(color, intensity * 0.14);
  ctx.fillRect(r.x, r.y, r.w, r.h);
  ctx.strokeStyle = rgba(color, intensity * 0.7);
  ctx.lineWidth = 0.8;
  const p = Math.min(r.w, r.h) * 0.2;
  ctx.beginPath();
  ctx.moveTo(r.x + p, r.y + p);
  ctx.lineTo(r.x + r.w - p, r.y + r.h - p);
  ctx.moveTo(r.x + r.w - p, r.y + p);
  ctx.lineTo(r.x + p, r.y + r.h - p);
  ctx.stroke();
}
