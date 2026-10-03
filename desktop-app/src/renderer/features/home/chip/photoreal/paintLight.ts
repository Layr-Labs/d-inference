import { smoothstep } from '../geometry';
import { rgba } from '../palette';
import {
  cacheLevel,
  cpuLevel,
  foreignGpu,
  gpuGlow,
  gpuLevel,
  gpuShare,
  interfaceLevel,
  ioPulse,
  neuralLevel,
} from '../render/activity';
import { along } from '../render/canvas';
import type { RenderFrame } from '../render/types';
import { drawSprite } from './atlas';
import { paintComets } from './comets';
import { drawAround, drawBlob } from './lightKit';
import { hot } from './materials';
import { paintMemory } from './memoryLight';
import type { PhotorealScene } from './scene';

/** Light thrown onto the substrate by busy silicon; kept on the package in light theme. */
function paintSpill(ctx: CanvasRenderingContext2D, built: PhotorealScene, frame: RenderFrame) {
  const { scene, kit } = built,
    w = frame.workload,
    dark = scene.palette.dark,
    k = (dark ? 1 : 0.6) * w.power,
    gpu = k * gpuGlow(frame),
    foreign = foreignGpu(frame);
  if (k < 0.01) return;
  ctx.save();
  if (!dark) ctx.clip(built.chip);
  for (const die of scene.layout.dies) {
    drawBlob(ctx, kit.blob.prefill, die, 1.6, w.prefill * 0.12 * gpu);
    drawBlob(ctx, kit.blob.decode, die, 1.55, w.decode * 0.08 * gpu);
    drawBlob(ctx, kit.blob.neutral, die, 1.55, foreign * 0.07 * gpu);
  }
  for (const block of built.gpuBlocks)
    drawBlob(ctx, kit.blob.prefill, block, 1.4, w.prefill * 0.06 * gpu);
  for (const pkg of scene.layout.memory) {
    drawBlob(ctx, kit.blob.kv, pkg, 1.6, w.kvFill * 0.1 * k);
    drawBlob(ctx, kit.blob.decode, pkg, 1.5, w.memoryRead * 0.07 * k);
    drawBlob(ctx, kit.blob.accent, pkg, 1.5, w.resident * 0.035 * k);
  }
  ctx.restore();
}

/** A request entering through the I/O pad, racing to the I/O block, which flares as it lands. */
function paintArrival(ctx: CanvasRenderingContext2D, built: PhotorealScene, frame: RenderFrame) {
  const pulse = ioPulse(frame);
  if (!pulse || pulse.strength < 0.01) return;
  const { scene, kit, glow, emissive } = built,
    unit = scene.layout.unit,
    [port, end] = scene.layout.io.path,
    head = along(port, end, pulse.at),
    tail = along(port, end, Math.max(0, pulse.at - 0.5));
  const streak = ctx.createLinearGradient(tail.x, tail.y, head.x, head.y);
  streak.addColorStop(0, rgba(glow.accent, 0));
  streak.addColorStop(1, rgba(hot(glow.accent, 0.4), 0.95));
  ctx.globalAlpha = Math.min(1, pulse.strength);
  ctx.strokeStyle = streak;
  ctx.lineWidth = Math.max(1.2, unit * 0.006);
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(tail.x, tail.y);
  ctx.lineTo(head.x, head.y);
  ctx.stroke();
  drawAround(ctx, kit.blob.accent, { ...head, w: 0, h: 0 }, unit * 0.045, pulse.strength);
  drawSprite(ctx, emissive.io, pulse.strength * smoothstep(0.55, 1, pulse.at));
}

/** The frame's light pass, composited additively over the static layer. */
export function paintLight(
  ctx: CanvasRenderingContext2D,
  built: PhotorealScene,
  frame: RenderFrame,
) {
  const { emissive } = built,
    w = frame.workload,
    power = w.power,
    glow = gpuGlow(frame),
    share = gpuShare(frame);
  ctx.globalCompositeOperation = 'lighter';
  paintSpill(ctx, built, frame);
  const gpuPower = power * Math.min(1.25, 0.75 + 0.25 * glow);
  for (const light of emissive.gpu) {
    const { prefill, decode } = gpuLevel(light.tile, frame),
      streamed = decode * 0.85 * (1 - 0.45 * Math.min(1, prefill)),
      level = Math.max(prefill, streamed);
    drawSprite(ctx, light.prefill, prefill * share * gpuPower, light.x, light.y);
    drawSprite(ctx, light.decode, streamed * share * gpuPower, light.x, light.y);
    drawSprite(ctx, light.neutral, level * (1 - share) * gpuPower, light.x, light.y);
  }
  for (const light of emissive.cpu)
    drawSprite(ctx, light.sprite, cpuLevel(light.tile, frame) * power, light.x, light.y);
  const cache = cacheLevel(frame) * power;
  for (const light of emissive.slc) drawSprite(ctx, light.sprite, cache, light.x, light.y);
  const neural = neuralLevel(frame);
  for (const light of emissive.neural) drawSprite(ctx, light.sprite, neural, light.x, light.y);
  const phy = interfaceLevel(frame) * power;
  for (const sprite of emissive.phy) drawSprite(ctx, sprite, phy);
  drawSprite(ctx, emissive.bridge, Math.max(w.prefill, w.decode * 0.6) * 0.8 * power);
  paintMemory(ctx, built, frame);
  paintComets(ctx, built, frame);
  paintArrival(ctx, built, frame);
  ctx.globalAlpha = 1;
  ctx.globalCompositeOperation = 'source-over';
}
