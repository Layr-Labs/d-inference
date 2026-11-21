import { clamp, inset } from '../geometry';
import type { ChipLayout, MemoryPackage } from '../layout';
import { css, rgba, type RGB } from '../palette';
import { seeded } from '../random';
import { roundRect } from '../render/canvas';
import { texture, type Brush } from './brush';

export const packageRadius = (unit: number) => unit * 0.016;
const WHITE: RGB = [255, 255, 255],
  LOT = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789',
  MONO = 'ui-monospace, SFMono-Regular, Menlo, monospace';

/** A generic lot and date code: four characters, then year and week. */
function lotCode(index: number) {
  const random = seeded(977 + index * 131),
    pick = () => LOT[Math.floor(random() * LOT.length)];
  const week = String(1 + Math.floor(random() * 52)).padStart(2, '0');
  return `${pick()}${pick()}${pick()}${pick()} 2${Math.floor(random() * 7)}${week}`;
}

/** Black epoxy LPDDR packages with laser markings; their cells glow through in the frame pass. */
export function paintPackages(brush: Brush, layout: ChipLayout, memoryGb: number, font: string) {
  const each = layout.memory.length ? memoryGb / layout.memory.length : 0,
    capacity = each >= 1 ? `${Math.round(each)}GB` : '';
  for (const pkg of layout.memory) paintPackage(brush, pkg, capacity, font);
}

function paintPackage(brush: Brush, pkg: MemoryPackage, capacity: string, font: string) {
  const { ctx, mats, unit, dpr, tex } = brush,
    radius = packageRadius(unit);
  ctx.save();
  ctx.shadowColor = `rgba(0,0,0,${mats.dark ? 0.72 : 0.45})`;
  ctx.shadowBlur = unit * 0.02 * dpr;
  ctx.shadowOffsetY = unit * 0.008 * dpr;
  ctx.fillStyle = css(mats.epoxy);
  roundRect(ctx, pkg, radius);
  ctx.fill();
  ctx.restore();

  ctx.save();
  roundRect(ctx, pkg, radius);
  ctx.clip();
  const body = ctx.createLinearGradient(pkg.x, pkg.y, pkg.x + pkg.w * 0.35, pkg.y + pkg.h);
  body.addColorStop(0, css(mats.epoxyTop));
  body.addColorStop(1, css(mats.epoxy));
  ctx.fillStyle = body;
  ctx.fillRect(pkg.x, pkg.y, pkg.w, pkg.h);
  texture(brush, pkg, tex.specks, mats.dark ? 0.32 : 0.38);
  texture(brush, pkg, tex.grain, 0.1);
  const sheen = ctx.createLinearGradient(pkg.x, pkg.y, pkg.x + pkg.w, pkg.y + pkg.h);
  sheen.addColorStop(0, rgba(WHITE, mats.gloss * 1.4));
  sheen.addColorStop(0.3, rgba(WHITE, mats.gloss * 0.45));
  sheen.addColorStop(0.46, rgba(WHITE, 0));
  ctx.fillStyle = sheen;
  ctx.fillRect(pkg.x, pkg.y, pkg.w, pkg.h);
  ctx.restore();

  const edge = ctx.createLinearGradient(pkg.x, pkg.y, pkg.x + pkg.w, pkg.y + pkg.h);
  edge.addColorStop(0, rgba(mats.rim, mats.rimStrength * 0.55));
  edge.addColorStop(0.4, rgba(mats.rim, 0.04));
  edge.addColorStop(1, 'rgba(0,0,0,0.55)');
  ctx.lineWidth = Math.max(1, unit * 0.003);
  ctx.strokeStyle = edge;
  roundRect(ctx, inset(pkg, ctx.lineWidth / 2), radius);
  ctx.stroke();
  markings(brush, pkg, capacity, font);
  pinOne(brush, pkg);
}

function markings(brush: Brush, pkg: MemoryPackage, capacity: string, font: string) {
  const { ctx, mats, unit } = brush,
    size = clamp(unit * 0.024, 5.5, 10),
    x = pkg.x + pkg.w / 2,
    y = pkg.y + pkg.h * 0.24;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle = rgba(mats.marking, mats.dark ? 0.2 : 0.24);
  ctx.font = `600 ${size}px ${font}`;
  ctx.letterSpacing = `${(size * 0.14).toFixed(2)}px`;
  if (ctx.measureText('LPDDR5X').width < pkg.w * 0.8) ctx.fillText('LPDDR5X', x, y);
  ctx.font = `500 ${size * 0.82}px ${MONO}`;
  ctx.letterSpacing = `${(size * 0.06).toFixed(2)}px`;
  const lines = [capacity, lotCode(pkg.index)].filter(Boolean);
  lines.forEach((line, i) => {
    if (ctx.measureText(line).width < pkg.w * 0.8)
      ctx.fillText(line, x, y + size * (1.35 + i * 1.1));
  });
  ctx.letterSpacing = '0px';
}

/** A shallow dimple marking pin 1. */
function pinOne(brush: Brush, pkg: MemoryPackage) {
  const { ctx, mats, unit } = brush,
    r = Math.max(1.2, unit * 0.0065),
    x = pkg.x + unit * 0.024,
    y = pkg.y + unit * 0.024;
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(0,0,0,0.6)';
  ctx.fill();
  ctx.beginPath();
  ctx.arc(x, y, r, Math.PI * 0.05, Math.PI * 0.95);
  ctx.lineWidth = Math.max(0.6, r * 0.35);
  ctx.strokeStyle = rgba(mats.marking, 0.16);
  ctx.stroke();
}
