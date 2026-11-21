import { center, inset, type Point, type Rect } from '../geometry';
import type { ChipLayout } from '../layout';
import { css, mix, rgba } from '../palette';
import { roundRect } from '../render/canvas';
import { texture, type Brush } from './brush';

export const substrateRadius = (unit: number) => unit * 0.034;

/** Solder-mask substrate: copper under the mask, vias, gold edge ring, and marks. */
export function paintSubstrate(brush: Brush, layout: ChipLayout, vias: Point[]) {
  const { ctx, mats, unit, tex } = brush,
    s = layout.substrate,
    radius = substrateRadius(unit);
  ctx.save();
  roundRect(ctx, s, radius);
  ctx.clip();
  const body = ctx.createLinearGradient(s.x, s.y, s.x + s.w * 0.4, s.y + s.h);
  body.addColorStop(0, css(mats.maskLight));
  body.addColorStop(1, css(mats.mask));
  ctx.fillStyle = body;
  ctx.fillRect(s.x, s.y, s.w, s.h);
  texture(brush, s, tex.grain, mats.dark ? 0.18 : 0.22);
  paintCopper(brush, layout);
  paintVias(brush, vias);
  const c = center(s),
    vignette = ctx.createRadialGradient(
      c.x,
      c.y,
      Math.min(s.w, s.h) * 0.3,
      c.x,
      c.y,
      Math.hypot(s.w, s.h) * 0.56,
    );
  vignette.addColorStop(0, 'rgba(0,0,0,0)');
  vignette.addColorStop(1, `rgba(0,0,0,${mats.dark ? 0.42 : 0.3})`);
  ctx.fillStyle = vignette;
  ctx.fillRect(s.x, s.y, s.w, s.h);
  ctx.restore();
  paintRing(brush, s, radius);
  paintMarks(brush, s);
  paintEdge(brush, s, radius);
}

const dot = (path: Path2D, p: Point, r: number) => {
  path.moveTo(p.x + r, p.y);
  path.arc(p.x, p.y, r, 0, Math.PI * 2);
};

/** Copper under solder mask reads as a raised, mask-tinted ridge with a faint metal core. */
function paintCopper(brush: Brush, layout: ChipLayout) {
  const { ctx, mats, unit } = brush,
    traces = new Path2D(),
    pads = new Path2D();
  for (const { from, to } of layout.traces) {
    traces.moveTo(from.x, from.y);
    traces.lineTo(to.x, to.y);
    dot(pads, from, Math.max(0.8, unit * 0.0045));
  }
  ctx.lineCap = 'round';
  ctx.strokeStyle = rgba(mix(mats.copper, mats.mask, 0.6), 0.85);
  ctx.lineWidth = Math.max(1, unit * 0.0062);
  ctx.stroke(traces);
  ctx.strokeStyle = rgba(mats.copper, mats.dark ? 0.3 : 0.36);
  ctx.lineWidth = Math.max(0.5, unit * 0.0024);
  ctx.stroke(traces);
  ctx.fillStyle = rgba(mats.copper, 0.28);
  ctx.fill(pads);
}

function paintVias(brush: Brush, vias: Point[]) {
  const { ctx, mats, unit } = brush,
    r = Math.max(0.7, unit * 0.0042),
    rings = new Path2D(),
    holes = new Path2D();
  for (const p of vias) {
    dot(rings, p, r);
    dot(holes, p, r * 0.45);
  }
  ctx.fillStyle = rgba(mix(mats.copper, mats.mask, 0.55), 0.8);
  ctx.fill(rings);
  ctx.fillStyle = 'rgba(0,0,0,0.55)';
  ctx.fill(holes);
}

function goldFill(ctx: CanvasRenderingContext2D, r: Rect, stops: Brush['mats']['gold']) {
  const metal = ctx.createLinearGradient(r.x, r.y, r.x + r.w, r.y + r.h);
  for (const [stop, color] of stops) metal.addColorStop(stop, color);
  return metal;
}

/** Plated ring in an opening of the solder mask, with a bright lip on the lit side. */
function paintRing(brush: Brush, s: Rect, radius: number) {
  const { ctx, mats, unit } = brush,
    at = unit * 0.02,
    width = Math.max(1.2, unit * 0.0085),
    r = inset(s, at),
    corner = Math.max(0, radius - at);
  roundRect(ctx, r, corner);
  ctx.lineWidth = width + 2;
  ctx.strokeStyle = 'rgba(0,0,0,0.35)';
  ctx.stroke();
  ctx.lineWidth = width;
  ctx.strokeStyle = goldFill(ctx, r, mats.gold);
  ctx.stroke();
  const lip = ctx.createLinearGradient(r.x, r.y, r.x + r.w * 0.6, r.y + r.h * 0.6);
  lip.addColorStop(0, 'rgba(255,248,224,0.55)');
  lip.addColorStop(1, 'rgba(255,248,224,0)');
  ctx.lineWidth = Math.max(0.5, width * 0.28);
  ctx.strokeStyle = lip;
  roundRect(ctx, inset(r, -width * 0.3), corner + width * 0.3);
  ctx.stroke();
}

/** Two domed fiducials in opposite corners and the pin-1 triangle. */
function paintMarks(brush: Brush, s: Rect) {
  const { ctx, mats, unit } = brush,
    at = unit * 0.06,
    r = unit * 0.0085;
  for (const [x, y] of [
    [s.x + at, s.y + s.h - at],
    [s.x + s.w - at, s.y + at],
  ]) {
    ctx.beginPath();
    ctx.arc(x, y, r * 2, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    ctx.fill();
    const pad = ctx.createRadialGradient(x - r * 0.35, y - r * 0.35, r * 0.1, x, y, r);
    pad.addColorStop(0, '#fff3c8');
    pad.addColorStop(0.45, '#d4ae55');
    pad.addColorStop(1, '#6b4f18');
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = pad;
    ctx.fill();
  }
  const p = unit * 0.045,
    leg = unit * 0.034;
  ctx.beginPath();
  ctx.moveTo(s.x + p, s.y + p);
  ctx.lineTo(s.x + p + leg, s.y + p);
  ctx.lineTo(s.x + p, s.y + p + leg);
  ctx.closePath();
  ctx.fillStyle = goldFill(ctx, { x: s.x + p, y: s.y + p, w: leg, h: leg }, mats.gold);
  ctx.fill();
}

/** The cut laminate edge, and the rim or key light catching the lit edges. */
function paintEdge(brush: Brush, s: Rect, radius: number) {
  const { ctx, mats, unit } = brush;
  ctx.lineWidth = 1;
  roundRect(ctx, inset(s, 0.5), radius);
  ctx.strokeStyle = rgba(mats.laminate, 0.35);
  ctx.stroke();
  const rim = ctx.createLinearGradient(s.x, s.y, s.x + s.w * 0.5, s.y + s.h * 0.75);
  rim.addColorStop(0, rgba(mats.rim, mats.rimStrength));
  rim.addColorStop(0.55, rgba(mats.rim, 0));
  ctx.lineWidth = Math.max(1, unit * 0.004);
  roundRect(ctx, inset(s, ctx.lineWidth / 2), radius);
  ctx.strokeStyle = rim;
  ctx.stroke();
}
