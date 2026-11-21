import type { Rect } from '../geometry';

/**
 * Fills a blurred silhouette of `path` without the path itself, by casting its shadow from
 * far off-canvas. Bake time only: shadow blur is too slow for the frame loop.
 */
export function blurredFill(
  ctx: CanvasRenderingContext2D,
  path: Path2D,
  blur: number,
  color: string,
) {
  const scale = ctx.getTransform().a,
    far = (ctx.canvas.width + 4096) / scale;
  ctx.save();
  ctx.shadowColor = color;
  ctx.shadowBlur = blur * scale;
  ctx.shadowOffsetX = far * scale;
  ctx.translate(-far, 0);
  ctx.fillStyle = '#000';
  ctx.fill(path);
  ctx.restore();
}

export function rectPath(r: Rect, radius = 0, path = new Path2D()) {
  if (radius > 0) path.roundRect(r.x, r.y, r.w, r.h, Math.min(radius, r.w / 2, r.h / 2));
  else path.rect(r.x, r.y, r.w, r.h);
  return path;
}
