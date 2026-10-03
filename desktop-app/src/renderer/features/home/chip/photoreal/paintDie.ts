import { inset, type Rect } from '../geometry';
import type { ChipLayout } from '../layout';
import { css, rgba } from '../palette';
import { seeded } from '../random';
import { roundRect } from '../render/canvas';
import { longAxis, texture, type Brush } from './brush';
import type { Materials } from './materials';
import { paintBlock, paintTile } from './paintSilicon';

export const dieRadius = (unit: number) => unit * 0.006;

/** The die shot: silicon, functional blocks, power grid, thin-film tint, seal ring and edges. */
export function paintDies(brush: Brush, layout: ChipLayout) {
  for (const die of layout.dies) dieBase(brush, die);
  for (const block of layout.blocks) paintBlock(brush, block);
  for (const tile of layout.tiles) paintTile(brush, tile);
  for (const die of layout.dies) dieFinish(brush, die);
  if (layout.bridge) paintBridge(brush, layout.bridge);
}

function dieBase(brush: Brush, die: Rect) {
  const { ctx, mats, unit, dpr, tex } = brush,
    radius = dieRadius(unit);
  // Underfill fillet spreading from under the die, then the die's own contact shadow.
  ctx.save();
  ctx.shadowColor = rgba(mats.underfill, 0.95);
  ctx.shadowBlur = unit * 0.016 * dpr;
  ctx.fillStyle = rgba(mats.underfill, 0.9);
  roundRect(ctx, inset(die, -unit * 0.005), radius * 2);
  ctx.fill();
  ctx.shadowColor = `rgba(0,0,0,${mats.dark ? 0.75 : 0.55})`;
  ctx.shadowBlur = unit * 0.014 * dpr;
  ctx.shadowOffsetY = unit * 0.005 * dpr;
  ctx.fillStyle = css(mats.silicon.fabric);
  roundRect(ctx, die, radius);
  ctx.fill();
  ctx.restore();
  ctx.save();
  roundRect(ctx, die, radius);
  ctx.clip();
  texture(brush, die, tex.logic, 0.4);
  texture(brush, die, tex.grain, 0.14);
  ctx.restore();
}

function dieFinish(brush: Brush, die: Rect) {
  const { ctx, mats, unit, dpr } = brush,
    radius = dieRadius(unit),
    line = 1 / dpr;
  ctx.save();
  roundRect(ctx, die, radius);
  ctx.clip();
  // Top-metal power straps.
  const pitch = Math.max(4, unit * 0.021);
  ctx.fillStyle = 'rgba(255,255,255,0.045)';
  for (let x = die.x + pitch / 2; x < die.x + die.w; x += pitch)
    ctx.fillRect(x, die.y, line, die.h);
  for (let y = die.y + pitch / 2; y < die.y + die.h; y += pitch)
    ctx.fillRect(die.x, y, die.w, line);
  // Thin-film interference: hue from the film, luminance from the silicon underneath.
  const film = ctx.createLinearGradient(die.x, die.y + die.h, die.x + die.w, die.y);
  for (const [stop, color] of mats.film) film.addColorStop(stop, css(color));
  ctx.fillStyle = film;
  ctx.globalCompositeOperation = 'color';
  ctx.globalAlpha = mats.filmStrength;
  ctx.fillRect(die.x, die.y, die.w, die.h);
  const patches = filmPatches(mats, die.x * 13 + die.y * 7);
  if (patches) {
    ctx.globalAlpha = mats.filmStrength * 0.9;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(
      patches,
      0.5,
      0.5,
      patches.width - 1,
      patches.height - 1,
      die.x,
      die.y,
      die.w,
      die.h,
    );
  }
  ctx.globalCompositeOperation = 'screen';
  ctx.globalAlpha = mats.filmStrength * 0.1;
  ctx.fillRect(die.x, die.y, die.w, die.h);
  ctx.globalCompositeOperation = 'source-over';
  ctx.globalAlpha = 1;
  // Softbox reflection across the polished surface: a broad band, then falling into shade.
  const sheen = ctx.createLinearGradient(die.x, die.y, die.x + die.w * 0.7, die.y + die.h);
  sheen.addColorStop(0, rgba([255, 255, 255], mats.gloss * 0.9));
  sheen.addColorStop(0.18, rgba([255, 255, 255], mats.gloss * 1.6));
  sheen.addColorStop(0.34, rgba([255, 255, 255], mats.gloss * 0.3));
  sheen.addColorStop(0.62, 'rgba(255,255,255,0)');
  sheen.addColorStop(1, `rgba(0,0,0,${mats.dark ? 0.2 : 0.14})`);
  ctx.fillStyle = sheen;
  ctx.fillRect(die.x, die.y, die.w, die.h);
  ctx.restore();
  sealRing(brush, die, line);
  // Chamfered edge: lit along the top and left, falling into shade bottom right.
  const edge = ctx.createLinearGradient(die.x, die.y, die.x + die.w, die.y + die.h);
  edge.addColorStop(0, rgba(mats.rim, mats.rimStrength * 0.85));
  edge.addColorStop(0.5, rgba(mats.rim, mats.rimStrength * 0.12));
  edge.addColorStop(1, 'rgba(0,0,0,0.6)');
  ctx.lineWidth = Math.max(line, unit * 0.0028);
  ctx.strokeStyle = edge;
  roundRect(ctx, inset(die, ctx.lineWidth / 2), radius);
  ctx.stroke();
}

/** A few pixels of random film hues; scaled up smoothly they become soft iridescent patches. */
function filmPatches(mats: Materials, seed: number) {
  const size = 7,
    canvas = document.createElement('canvas'),
    random = seeded(Math.round(seed));
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++) {
      ctx.fillStyle = css(mats.film[Math.floor(random() * mats.film.length)][1]);
      ctx.fillRect(x, y, 1, 1);
    }
  return canvas;
}

function sealRing(brush: Brush, die: Rect, line: number) {
  const { ctx, mats, unit } = brush;
  for (const [depth, alpha, width] of [
    [0.0055, 0.5, 1.6],
    [0.009, 0.28, 1],
    [0.0122, 0.18, 1],
  ]) {
    const r = inset(die, unit * depth);
    ctx.lineWidth = line * width;
    ctx.strokeStyle = rgba(mats.silicon.seal, alpha);
    ctx.strokeRect(r.x, r.y, r.w, r.h);
  }
  // Alignment marks in the corners, inside the ring.
  const mark = unit * 0.022,
    at = unit * 0.018;
  ctx.lineWidth = line * 1.4;
  ctx.strokeStyle = rgba(mats.silicon.seal, 0.32);
  ctx.beginPath();
  for (const [x, y, dx, dy] of [
    [die.x + at, die.y + at, 1, 1],
    [die.x + die.w - at, die.y + at, -1, 1],
    [die.x + at, die.y + die.h - at, 1, -1],
    [die.x + die.w - at, die.y + die.h - at, -1, -1],
  ]) {
    ctx.moveTo(x, y + dy * mark);
    ctx.lineTo(x, y);
    ctx.lineTo(x + dx * mark, y);
  }
  ctx.stroke();
}

/** The die-to-die bridge: a dark interposer crossed by dense wiring. */
function paintBridge(brush: Brush, bridge: Rect) {
  const { ctx, mats, tex, dpr } = brush;
  ctx.fillStyle = css(mats.silicon.spine);
  ctx.fillRect(bridge.x, bridge.y, bridge.w, bridge.h);
  texture(brush, bridge, tex.glow.lanes[longAxis(bridge)], 0.3, css(mats.silicon.seal));
  ctx.lineWidth = 1 / dpr;
  ctx.strokeStyle = rgba(mats.silicon.seal, 0.35);
  ctx.strokeRect(bridge.x, bridge.y, bridge.w, bridge.h);
}
