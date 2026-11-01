import type { Point, Rect } from '../geometry';

export interface Layer {
  canvas: HTMLCanvasElement;
  ctx: CanvasRenderingContext2D;
}
/** An offscreen layer sized in CSS pixels, drawn at device resolution. */
export function createLayer(width: number, height: number, dpr: number): Layer | null {
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(width * dpr));
  canvas.height = Math.max(1, Math.round(height * dpr));
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return { canvas, ctx };
}
export function roundRect(ctx: CanvasRenderingContext2D, r: Rect, radius: number) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.w, r.h, Math.max(0, Math.min(radius, r.w / 2, r.h / 2)));
}
export const tileRadius = (r: Rect, max = 3.5) =>
  Math.max(1, Math.min(max, Math.min(r.w, r.h) * 0.16));
/** Repeating I/O cells across a strip, perpendicular to its long axis, in the current stroke. */
export function strokeTicks(ctx: CanvasRenderingContext2D, r: Rect, spacing = 2.6) {
  const horizontal = r.w > r.h;
  ctx.beginPath();
  if (horizontal)
    for (let x = r.x + spacing / 2; x < r.x + r.w; x += spacing) {
      ctx.moveTo(x, r.y + r.h * 0.2);
      ctx.lineTo(x, r.y + r.h * 0.8);
    }
  else
    for (let y = r.y + spacing / 2; y < r.y + r.h; y += spacing) {
      ctx.moveTo(r.x + r.w * 0.2, y);
      ctx.lineTo(r.x + r.w * 0.8, y);
    }
  ctx.stroke();
}
export const along = (a: Point, b: Point, t: number): Point => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
});

/**
 * Pre-blurred halos keyed by size and colour, so per-frame glow is a single drawImage
 * instead of a live shadow blur.
 */
export function createGlowCache(dpr: number) {
  const sprites = new Map<string, { canvas: HTMLCanvasElement; pad: number }>();
  const OFFSET = 4096;
  return {
    draw(ctx: CanvasRenderingContext2D, r: Rect, radius: number, blur: number, color: string) {
      const key = `${Math.round(r.w * 2)}|${Math.round(r.h * 2)}|${radius.toFixed(1)}|${blur}|${color}`;
      let sprite = sprites.get(key);
      if (!sprite) {
        const pad = blur * 2,
          layer = createLayer(r.w + pad * 2, r.h + pad * 2, dpr);
        if (!layer) return;
        layer.ctx.shadowColor = color;
        layer.ctx.shadowBlur = blur * dpr;
        layer.ctx.shadowOffsetX = OFFSET * dpr;
        layer.ctx.fillStyle = '#000';
        roundRect(layer.ctx, { x: pad - OFFSET, y: pad, w: r.w, h: r.h }, radius);
        layer.ctx.fill();
        sprite = { canvas: layer.canvas, pad };
        sprites.set(key, sprite);
      }
      ctx.drawImage(
        sprite.canvas,
        r.x - sprite.pad,
        r.y - sprite.pad,
        r.w + sprite.pad * 2,
        r.h + sprite.pad * 2,
      );
    },
    clear() {
      sprites.clear();
    },
  };
}
export type GlowCache = ReturnType<typeof createGlowCache>;
