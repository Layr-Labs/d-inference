import { inset } from '../geometry';
import type { Block, ChipLayout, Tile } from '../layout';
import { rgba, type ChipPalette } from '../palette';
import { roundRect, strokeTicks, tileRadius } from '../render/canvas';
import type { ChipScene } from '../render/types';
import { drawLabel, labelPlacements } from './labels';
import { paintMemoryPackages, paintTraces, type Ink } from './paintMemory';

/** Everything that does not change frame to frame: drawn once per size, theme and model set. */
export function paintBlueprintStatic(ctx: CanvasRenderingContext2D, scene: ChipScene) {
  const { layout, palette, memory, dpr } = scene,
    dark = palette.dark,
    ink: Ink = (alpha) => rgba(palette.contrast, alpha);
  ctx.clearRect(0, 0, layout.width, layout.height);
  ctx.lineWidth = Math.max(0.6, 1 / dpr);
  dotGrid(ctx, layout, ink(dark ? 0.1 : 0.12));
  substrate(ctx, layout, ink, dark);
  paintMemoryPackages(ctx, layout, memory, ink, dark);
  paintTraces(ctx, layout, ink, dark);
  dies(ctx, layout, ink, dark);
  for (const block of layout.blocks) paintBlock(ctx, block, layout.unit, ink, dark);
  for (const tile of layout.tiles) paintTile(ctx, tile, ink, dark);
  labels(ctx, layout, palette);
}

function dotGrid(ctx: CanvasRenderingContext2D, layout: ChipLayout, color: string) {
  const spacing = Math.max(12, layout.unit * 0.045),
    cx = layout.width / 2,
    cy = layout.height / 2;
  ctx.fillStyle = color;
  for (let x = (layout.width % spacing) / 2; x < layout.width; x += spacing)
    for (let y = (layout.height % spacing) / 2; y < layout.height; y += spacing)
      ctx.fillRect(x - 0.5, y - 0.5, 1, 1);
  const fade = ctx.createRadialGradient(
    cx,
    cy,
    0,
    cx,
    cy,
    Math.max(layout.width, layout.height) * 0.58,
  );
  fade.addColorStop(0, 'rgba(0,0,0,1)');
  fade.addColorStop(0.5, 'rgba(0,0,0,0.55)');
  fade.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.globalCompositeOperation = 'destination-in';
  ctx.fillStyle = fade;
  ctx.fillRect(0, 0, layout.width, layout.height);
  ctx.globalCompositeOperation = 'source-over';
}

function substrate(ctx: CanvasRenderingContext2D, layout: ChipLayout, ink: Ink, dark: boolean) {
  const s = layout.substrate,
    u = layout.unit;
  roundRect(ctx, s, u * 0.045);
  ctx.fillStyle = dark ? ink(0.022) : 'rgba(255,255,255,0.94)';
  ctx.fill();
  ctx.strokeStyle = ink(dark ? 0.15 : 0.13);
  ctx.stroke();
  const mark = u * 0.05,
    gap = u * 0.028;
  ctx.strokeStyle = ink(dark ? 0.32 : 0.3);
  ctx.beginPath();
  for (const [x, y, dx, dy] of [
    [s.x, s.y, -1, -1],
    [s.x + s.w, s.y, 1, -1],
    [s.x, s.y + s.h, -1, 1],
    [s.x + s.w, s.y + s.h, 1, 1],
  ]) {
    const px = x + dx * gap,
      py = y + dy * gap;
    ctx.moveTo(px, py - dy * mark);
    ctx.lineTo(px, py);
    ctx.lineTo(px - dx * mark, py);
  }
  ctx.stroke();
  const pin = u * 0.032,
    px = s.x + u * 0.045,
    py = s.y + u * 0.045;
  ctx.fillStyle = ink(dark ? 0.3 : 0.28);
  ctx.beginPath();
  ctx.moveTo(px, py);
  ctx.lineTo(px + pin, py);
  ctx.lineTo(px, py + pin);
  ctx.closePath();
  ctx.fill();
}

function dies(ctx: CanvasRenderingContext2D, layout: ChipLayout, ink: Ink, dark: boolean) {
  const u = layout.unit,
    line = ctx.lineWidth;
  for (const die of layout.dies) {
    roundRect(ctx, die, u * 0.022);
    ctx.fillStyle = dark ? ink(0.035) : '#fff';
    ctx.fill();
    ctx.lineWidth = line * 1.4;
    ctx.strokeStyle = ink(dark ? 0.26 : 0.22);
    ctx.stroke();
    ctx.lineWidth = line;
    roundRect(ctx, inset(die, u * 0.012), u * 0.016);
    ctx.strokeStyle = ink(0.07);
    ctx.stroke();
    if (!dark) continue;
    const sheen = ctx.createLinearGradient(die.x, die.y, die.x + die.w * 0.7, die.y + die.h);
    sheen.addColorStop(0, ink(0.045));
    sheen.addColorStop(0.55, ink(0));
    roundRect(ctx, die, u * 0.022);
    ctx.fillStyle = sheen;
    ctx.fill();
  }
  if (layout.bridge) {
    ctx.fillStyle = ink(dark ? 0.1 : 0.12);
    ctx.fillRect(layout.bridge.x, layout.bridge.y, layout.bridge.w, layout.bridge.h);
  }
}

function paintBlock(
  ctx: CanvasRenderingContext2D,
  block: Block,
  unit: number,
  ink: Ink,
  dark: boolean,
) {
  if (block.kind === 'interface') {
    ctx.fillStyle = ink(dark ? 0.05 : 0.05);
    ctx.fillRect(block.x, block.y, block.w, block.h);
    ctx.strokeStyle = ink(dark ? 0.13 : 0.15);
    strokeTicks(ctx, block);
    return;
  }
  roundRect(ctx, block, unit * 0.01);
  ctx.fillStyle = ink(dark ? 0.014 : 0.016);
  ctx.fill();
  ctx.strokeStyle = ink(dark ? 0.085 : 0.1);
  ctx.stroke();
}

function paintTile(ctx: CanvasRenderingContext2D, tile: Tile, ink: Ink, dark: boolean) {
  const radius = tileRadius(tile);
  roundRect(ctx, tile, radius);
  if (tile.filler) {
    ctx.fillStyle = ink(0.022);
    ctx.fill();
    return;
  }
  if (tile.kind === 'l2') {
    ctx.fillStyle = ink(0.03);
    ctx.fill();
    ctx.save();
    ctx.clip();
    const horizontal = tile.w >= tile.h;
    ctx.strokeStyle = ink(dark ? 0.06 : 0.07);
    ctx.beginPath();
    for (let at = 1.5; at < (horizontal ? tile.h : tile.w); at += 2.4) {
      if (horizontal) {
        ctx.moveTo(tile.x, tile.y + at);
        ctx.lineTo(tile.x + tile.w, tile.y + at);
      } else {
        ctx.moveTo(tile.x + at, tile.y);
        ctx.lineTo(tile.x + at, tile.y + tile.h);
      }
    }
    ctx.stroke();
    ctx.restore();
    roundRect(ctx, tile, radius);
    ctx.strokeStyle = ink(0.075);
    ctx.stroke();
    return;
  }
  ctx.fillStyle = ink(dark ? 0.045 : 0.04);
  ctx.fill();
  ctx.strokeStyle = ink(dark ? 0.11 : 0.12);
  ctx.stroke();
  if (tile.kind !== 'gpu' || Math.min(tile.w, tile.h) < 12) return;
  // Shader-core quadrants, faint enough to read through the lit fill.
  const core = inset(tile, tile.w * 0.2, tile.h * 0.22),
    mx = tile.x + tile.w / 2,
    my = tile.y + tile.h / 2;
  ctx.strokeStyle = ink(dark ? 0.08 : 0.09);
  ctx.beginPath();
  ctx.moveTo(mx, core.y);
  ctx.lineTo(mx, core.y + core.h);
  ctx.moveTo(core.x, my);
  ctx.lineTo(core.x + core.w, my);
  ctx.stroke();
}

function labels(ctx: CanvasRenderingContext2D, layout: ChipLayout, palette: ChipPalette) {
  const size = Math.max(7.5, Math.min(10.5, layout.unit * 0.028)),
    font = (px: number) => `600 ${px.toFixed(2)}px ${palette.font}`;
  ctx.font = font(size);
  ctx.letterSpacing = `${(size * 0.12).toFixed(2)}px`;
  for (const block of layout.blocks) {
    if (block.kind === 'interface') continue;
    ctx.fillStyle = rgba(palette.text, palette.dark ? 0.52 : 0.58);
    drawLabel(ctx, block.label.toUpperCase(), labelPlacements(block), size, font);
  }
  const first = layout.memory[0];
  if (first) {
    ctx.fillStyle = rgba(palette.text, palette.dark ? 0.52 : 0.58);
    ctx.textBaseline = 'alphabetic';
    const right = first.side === 'right';
    ctx.textAlign = right ? 'right' : 'left';
    ctx.fillText('UNIFIED MEMORY', right ? first.x + first.w : first.x, first.y - size * 0.8);
  }
  ctx.letterSpacing = '0px';
}
