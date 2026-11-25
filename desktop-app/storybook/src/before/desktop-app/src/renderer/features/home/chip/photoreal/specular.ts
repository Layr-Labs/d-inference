import { center } from '../geometry';
import type { RenderFrame } from '../render/types';
import { drawBlob } from './lightKit';
import type { PhotorealScene } from './scene';

const SWEEP_SECONDS = 11,
  SWEEP_SHARE = 0.55;

/**
 * Studio light gliding across the polished die and package tops every few seconds, nudged
 * by the pointer; under reduced motion only the baked reflections remain.
 */
export function paintSpecular(
  ctx: CanvasRenderingContext2D,
  built: PhotorealScene,
  frame: RenderFrame,
) {
  const { kit, scene } = built;
  if (!frame.motion || !kit.sheen) return;
  const s = scene.layout.substrate,
    c = center(s),
    reach = Math.hypot(s.w, s.h),
    pointer = frame.pointer,
    progress = ((frame.workload.time / SWEEP_SECONDS) % 1) / SWEEP_SHARE,
    strength = (scene.palette.dark ? 0.13 : 0.15) * (0.55 + 0.45 * frame.workload.power);
  ctx.save();
  ctx.clip(built.gloss);
  ctx.globalCompositeOperation = 'lighter';
  if (progress <= 1) {
    const offset = (progress - 0.5) * reach * 1.25 + (pointer ? pointer.x * reach * 0.08 : 0),
      angle = -0.62 + (pointer ? pointer.y * 0.22 : 0),
      band = reach * 0.2;
    ctx.save();
    ctx.globalAlpha = strength * Math.sin(Math.PI * progress) ** 1.5;
    ctx.translate(c.x, c.y);
    ctx.rotate(angle);
    ctx.drawImage(kit.sheen, offset - band / 2, -reach / 2, band, reach);
    ctx.restore();
  }
  if (pointer) {
    const size = reach * 0.34,
      x = c.x + pointer.x * s.w * 0.42,
      y = c.y + pointer.y * s.h * 0.42;
    drawBlob(
      ctx,
      kit.blob.white,
      { x: x - size / 2, y: y - size / 2, w: size, h: size },
      1,
      strength * 0.8,
    );
  }
  ctx.restore();
}
