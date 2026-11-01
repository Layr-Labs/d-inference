import type { ChipRenderer } from '../render/types';
import { paintLight } from './paintLight';
import { paintPowerOff } from './powerOff';
import { buildScene, releaseScene, type PhotorealScene } from './scene';
import { paintSpecular } from './specular';
import { createTextures, type Textures } from './textures';

/**
 * Showpiece variant: a procedurally rendered SoC package whose silicon and memory glow
 * through their own texture as inference runs.
 */
export function createPhotorealRenderer(ctx: CanvasRenderingContext2D): ChipRenderer {
  let textures: Textures | null = null,
    built: PhotorealScene | null = null;
  return {
    setScene(scene) {
      textures ??= createTextures();
      releaseScene(built);
      built = buildScene(scene, textures);
    },
    draw(frame) {
      if (!built) return;
      const { dpr } = built.scene;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.globalAlpha = 1;
      ctx.globalCompositeOperation = 'source-over';
      ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
      ctx.drawImage(built.base.canvas, 0, 0);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      paintPowerOff(ctx, built, frame.workload.power);
      paintLight(ctx, built, frame);
      paintSpecular(ctx, built, frame);
    },
    dispose() {
      releaseScene(built);
      built = null;
      textures = null;
    },
  };
}
