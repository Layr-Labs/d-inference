import { clamp } from '../geometry';
import type { PhotorealScene } from './scene';

/** A stopped provider reads as an unpowered part: mostly desaturated and a little darker. */
export function paintPowerOff(ctx: CanvasRenderingContext2D, built: PhotorealScene, power: number) {
  const off = clamp(1 - power);
  if (off < 0.005) return;
  ctx.save();
  ctx.globalCompositeOperation = 'saturation';
  ctx.fillStyle = `rgba(128,128,128,${off * 0.75})`;
  ctx.fill(built.chip);
  ctx.globalCompositeOperation = 'source-over';
  ctx.fillStyle = `rgba(0,0,0,${off * (built.scene.palette.dark ? 0.38 : 0.22)})`;
  ctx.fill(built.chip);
  ctx.restore();
}
