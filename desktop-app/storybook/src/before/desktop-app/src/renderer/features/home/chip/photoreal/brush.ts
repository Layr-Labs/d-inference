import type { Point, Rect } from '../geometry';
import type { Materials } from './materials';
import type { Textures } from './textures';

/** A baking target with its scale, the theme's materials and device-pixel texture patterns. */
export interface Brush {
  ctx: CanvasRenderingContext2D;
  dpr: number;
  unit: number;
  mats: Materials;
  tex: Textures;
  /** `tile` repeated with one texel per device pixel, optionally tinted (for alpha masks). */
  pattern(tile: HTMLCanvasElement, tint?: string): CanvasPattern | null;
}

const ORIGIN: Point = { x: 0, y: 0 };
export const longAxis = (r: Rect): 'x' | 'y' => (r.w >= r.h ? 'x' : 'y');
/** `value` rounded to the device-pixel grid. */
export const snap = (value: number, dpr: number) => Math.round(value * dpr) / dpr;

function tinted(tile: HTMLCanvasElement, color: string) {
  const canvas = document.createElement('canvas');
  canvas.width = tile.width;
  canvas.height = tile.height;
  const ctx = canvas.getContext('2d');
  if (!ctx) return canvas;
  ctx.drawImage(tile, 0, 0);
  ctx.globalCompositeOperation = 'source-in';
  ctx.fillStyle = color;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  return canvas;
}

export function createBrush(
  ctx: CanvasRenderingContext2D,
  dpr: number,
  unit: number,
  mats: Materials,
  tex: Textures,
): Brush {
  const cache = new Map<HTMLCanvasElement, Map<string, CanvasPattern | null>>();
  return {
    ctx,
    dpr,
    unit,
    mats,
    tex,
    pattern(tile, tint = '') {
      let byTint = cache.get(tile);
      if (!byTint) cache.set(tile, (byTint = new Map()));
      if (!byTint.has(tint))
        byTint.set(tint, ctx.createPattern(tint ? tinted(tile, tint) : tile, 'repeat'));
      return byTint.get(tint) ?? null;
    },
  };
}

/**
 * Covers `r` with a texture at `alpha`, optionally tinted. Texels start at `anchor` (a point
 * on the device grid), so a part and its emissive sprite share one texture phase.
 */
export function texture(
  brush: Brush,
  r: Rect,
  tile: HTMLCanvasElement,
  alpha: number,
  tint?: string,
  anchor: Point = ORIGIN,
) {
  const pattern = brush.pattern(tile, tint);
  if (!pattern || alpha <= 0) return;
  const { ctx, dpr } = brush;
  // Patterns live in user space; undo the layer's scale so texels stay device pixels.
  pattern.setTransform(new DOMMatrix([1 / dpr, 0, 0, 1 / dpr, anchor.x, anchor.y]));
  ctx.globalAlpha = alpha;
  ctx.fillStyle = pattern;
  ctx.fillRect(r.x, r.y, r.w, r.h);
  ctx.globalAlpha = 1;
}
