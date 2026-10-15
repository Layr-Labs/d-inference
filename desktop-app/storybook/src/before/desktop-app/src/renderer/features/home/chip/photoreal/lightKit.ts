import { center, inset, type Rect } from '../geometry';
import { rgba, type RGB } from '../palette';
import { createLayer } from '../render/canvas';
import { blurredFill, rectPath } from './glow';
import { hot, type Glow } from './materials';

/** A per-cell highlight sprite and the margin (CSS pixels) it extends past the cell. */
export interface CellFlash {
  canvas: HTMLCanvasElement;
  pad: number;
}
/** Shared, scalable light sprites; drawn stretched, so they carry no fine structure. */
export interface LightKit {
  blob: Record<keyof Glow | 'white', HTMLCanvasElement | null>;
  /** Soft rounded-rect glow stretched over runs of filled KV cells. */
  haze: HTMLCanvasElement | null;
  /** Decode streaming a weight cell, and KV cells being read or written. */
  flash: { weights: CellFlash | null; kv: CellFlash | null };
  /** A bright band swept across glossy surfaces. */
  sheen: HTMLCanvasElement | null;
}

const BLOB_FALLOFF = [
  [0, 1],
  [0.2, 0.78],
  [0.42, 0.42],
  [0.65, 0.15],
  [0.85, 0.04],
  [1, 0],
] as const;
const SHEEN_PROFILE = [
  [0, 0],
  [0.28, 0.1],
  [0.45, 0.5],
  [0.5, 1],
  [0.55, 0.5],
  [0.72, 0.1],
  [1, 0],
] as const;

function blob(color: RGB) {
  const size = 64,
    layer = createLayer(size, size, 1);
  if (!layer) return null;
  const middle = size / 2,
    gradient = layer.ctx.createRadialGradient(middle, middle, 0, middle, middle, middle);
  for (const [stop, alpha] of BLOB_FALLOFF) gradient.addColorStop(stop, rgba(color, alpha));
  layer.ctx.fillStyle = gradient;
  layer.ctx.fillRect(0, 0, size, size);
  return layer.canvas;
}

function haze(color: RGB) {
  const w = 96,
    h = 64,
    blur = 11,
    layer = createLayer(w, h, 1);
  if (!layer) return null;
  const body = rectPath(inset({ x: 0, y: 0, w, h }, blur * 1.6), 8);
  blurredFill(layer.ctx, body, blur, rgba(color, 1));
  return layer.canvas;
}

function flash(cell: Rect, color: RGB, dpr: number): CellFlash | null {
  const pad = Math.max(3, Math.min(cell.w, cell.h) * 0.7),
    layer = createLayer(cell.w + pad * 2, cell.h + pad * 2, dpr);
  if (!layer) return null;
  const r = { x: pad, y: pad, w: cell.w, h: cell.h },
    radius = Math.min(cell.w, cell.h) * 0.2;
  blurredFill(layer.ctx, rectPath(r, radius), pad * 0.55, rgba(color, 0.75));
  blurredFill(layer.ctx, rectPath(inset(r, 0.6), radius), 1.2, rgba(hot(color, 0.6), 0.95));
  return { canvas: layer.canvas, pad };
}

function sheen() {
  const layer = createLayer(256, 4, 1);
  if (!layer) return null;
  const gradient = layer.ctx.createLinearGradient(0, 0, 256, 0);
  for (const [stop, alpha] of SHEEN_PROFILE)
    gradient.addColorStop(stop, `rgba(255,255,255,${alpha})`);
  layer.ctx.fillStyle = gradient;
  layer.ctx.fillRect(0, 0, 256, 4);
  return layer.canvas;
}

/** `cell` is a representative memory cell; every package shares one cell size. */
export function buildLightKit(glow: Glow, cell: Rect | null, dpr: number): LightKit {
  return {
    blob: {
      prefill: blob(glow.prefill),
      decode: blob(glow.decode),
      kv: blob(glow.kv),
      cpu: blob(glow.cpu),
      accent: blob(glow.accent),
      neutral: blob(glow.neutral),
      white: blob([255, 255, 255]),
    },
    haze: haze(glow.kv),
    flash: {
      weights: cell ? flash(cell, glow.decode, dpr) : null,
      kv: cell ? flash(cell, hot(glow.kv, 0.45), dpr) : null,
    },
    sheen: sheen(),
  };
}

/** Draws `image` stretched over `r` grown by `pad` on every side. */
export function drawAround(
  ctx: CanvasRenderingContext2D,
  image: HTMLCanvasElement | null,
  r: Rect,
  pad: number,
  alpha: number,
) {
  if (!image || alpha < 0.004) return;
  ctx.globalAlpha = Math.min(1, alpha);
  ctx.drawImage(image, r.x - pad, r.y - pad, r.w + pad * 2, r.h + pad * 2);
}

/** A soft light sprite centred on `r`, scaled by `spread`. */
export function drawBlob(
  ctx: CanvasRenderingContext2D,
  blob: HTMLCanvasElement | null,
  r: Rect,
  spread: number,
  alpha: number,
) {
  if (!blob || alpha < 0.004) return;
  const c = center(r),
    w = r.w * spread,
    h = r.h * spread;
  ctx.globalAlpha = Math.min(1, alpha);
  ctx.drawImage(blob, c.x - w / 2, c.y - h / 2, w, h);
}
