import { createGlowCache, createLayer, type GlowCache, type Layer } from '../render/canvas';
import type { ChipRenderer, ChipScene } from '../render/types';
import { paintBlueprintActivity } from './paintActivity';
import { paintBlueprintStatic } from './paintStatic';

/** Fit-for-purpose variant: a crisp on-brand schematic where only active parts light up. */
export function createBlueprintRenderer(ctx: CanvasRenderingContext2D): ChipRenderer {
  let scene: ChipScene | null = null,
    base: Layer | null = null,
    glow: GlowCache | null = null;
  return {
    setScene(next) {
      scene = next;
      base = createLayer(next.layout.width, next.layout.height, next.dpr);
      if (base) paintBlueprintStatic(base.ctx, next);
      glow?.clear();
      glow = createGlowCache(next.dpr);
    },
    draw(frame) {
      if (!scene || !base || !glow) return;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, ctx.canvas.width, ctx.canvas.height);
      ctx.globalAlpha = 0.45 + 0.55 * frame.workload.power;
      ctx.drawImage(base.canvas, 0, 0);
      ctx.globalAlpha = 1;
      ctx.setTransform(scene.dpr, 0, 0, scene.dpr, 0, 0);
      paintBlueprintActivity(ctx, scene, frame, glow);
    },
    dispose() {
      glow?.clear();
      scene = null;
      base = null;
      glow = null;
    },
  };
}
