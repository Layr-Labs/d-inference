import type { Rect } from '../geometry';

/** A baked image placed in stage coordinates; its source rect maps 1:1 onto device pixels. */
export interface Sprite {
  source: HTMLCanvasElement;
  sx: number;
  sy: number;
  sw: number;
  sh: number;
  x: number;
  y: number;
  w: number;
  h: number;
}
export type Paint = (ctx: CanvasRenderingContext2D) => void;

interface Slot {
  x0: number;
  y0: number;
  sw: number;
  sh: number;
  paint: Paint;
  ax: number;
  ay: number;
}
const GUTTER = 2,
  MAX_WIDTH = 4096;

/**
 * Collects images painted in stage coordinates and packs them into one canvas, so the frame
 * pass draws sub-rects of a single texture. Slots snap to device pixels, so light lands
 * exactly on the texture it shines through.
 */
export function createAtlas(dpr: number) {
  const slots: Slot[] = [];
  return {
    /** Queues `paint` over `bounds` grown by `pad`; returns the sprite's index in `build()`. */
    add(bounds: Rect, pad: number, paint: Paint) {
      const x0 = Math.floor((bounds.x - pad) * dpr),
        y0 = Math.floor((bounds.y - pad) * dpr);
      const sw = Math.max(1, Math.ceil((bounds.x + bounds.w + pad) * dpr) - x0),
        sh = Math.max(1, Math.ceil((bounds.y + bounds.h + pad) * dpr) - y0);
      slots.push({ x0, y0, sw, sh, paint, ax: 0, ay: 0 });
      return slots.length - 1;
    },
    build(): Sprite[] {
      if (!slots.length) return [];
      const area = slots.reduce((sum, s) => sum + (s.sw + GUTTER) * (s.sh + GUTTER), 0);
      const width = Math.min(
        MAX_WIDTH,
        Math.max(Math.ceil(Math.sqrt(area) * 1.15), ...slots.map((s) => s.sw + GUTTER)),
      );
      let x = 0,
        y = 0,
        shelf = 0;
      for (const slot of [...slots].sort((a, b) => b.sh - a.sh)) {
        if (x + slot.sw + GUTTER > width) {
          x = 0;
          y += shelf;
          shelf = 0;
        }
        slot.ax = x;
        slot.ay = y;
        x += slot.sw + GUTTER;
        shelf = Math.max(shelf, slot.sh + GUTTER);
      }
      const canvas = document.createElement('canvas');
      canvas.width = width;
      canvas.height = Math.max(1, y + shelf);
      const ctx = canvas.getContext('2d');
      if (!ctx) return [];
      for (const slot of slots) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(slot.ax, slot.ay, slot.sw, slot.sh);
        ctx.clip();
        ctx.setTransform(dpr, 0, 0, dpr, slot.ax - slot.x0, slot.ay - slot.y0);
        slot.paint(ctx);
        ctx.restore();
      }
      return slots.map((slot) => ({
        source: canvas,
        sx: slot.ax,
        sy: slot.ay,
        sw: slot.sw,
        sh: slot.sh,
        x: slot.x0 / dpr,
        y: slot.y0 / dpr,
        w: slot.sw / dpr,
        h: slot.sh / dpr,
      }));
    },
  };
}

/**
 * Draws `sprite` at `alpha`. A sprite shared by several identical parts was baked around a
 * local origin; (`x`, `y`) is where that origin lands, on the device grid.
 */
export function drawSprite(
  ctx: CanvasRenderingContext2D,
  sprite: Sprite | null,
  alpha: number,
  x = 0,
  y = 0,
) {
  if (!sprite || alpha < 0.004) return;
  ctx.globalAlpha = Math.min(1, alpha);
  ctx.drawImage(
    sprite.source,
    sprite.sx,
    sprite.sy,
    sprite.sw,
    sprite.sh,
    x + sprite.x,
    y + sprite.y,
    sprite.w,
    sprite.h,
  );
}

/** Draws the part of `sprite` under `r` (stage coordinates), cut on device pixels. */
export function drawSpriteRegion(
  ctx: CanvasRenderingContext2D,
  sprite: Sprite | null,
  r: Rect,
  alpha: number,
  x = 0,
  y = 0,
) {
  if (!sprite || alpha < 0.004) return;
  const scale = sprite.sw / sprite.w,
    left = x + sprite.x,
    top = y + sprite.y,
    x0 = Math.max(0, Math.round((r.x - left) * scale)),
    y0 = Math.max(0, Math.round((r.y - top) * scale)),
    x1 = Math.min(sprite.sw, Math.round((r.x + r.w - left) * scale)),
    y1 = Math.min(sprite.sh, Math.round((r.y + r.h - top) * scale));
  if (x1 <= x0 || y1 <= y0) return;
  ctx.globalAlpha = Math.min(1, alpha);
  ctx.drawImage(
    sprite.source,
    sprite.sx + x0,
    sprite.sy + y0,
    x1 - x0,
    y1 - y0,
    left + x0 / scale,
    top + y0 / scale,
    (x1 - x0) / scale,
    (y1 - y0) / scale,
  );
}
