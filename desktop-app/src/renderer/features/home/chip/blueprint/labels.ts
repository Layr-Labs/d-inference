import type { Block } from '../layout';

interface Placement {
  x: number;
  y: number;
  angle: number;
  align: CanvasTextAlign;
  /** Length available along the text direction. */
  room: number;
  /** Thickness available across the text direction. */
  band: number;
}

/** Candidate spots for a block's label: its label band, or centred (flat, then upright). */
export function labelPlacements(block: Block): Placement[] {
  const margins = {
    top: block.body.y - block.y,
    bottom: block.y + block.h - block.body.y - block.body.h,
    left: block.body.x - block.x,
    right: block.x + block.w - block.body.x - block.body.w,
  };
  const widest = Math.max(margins.top, margins.bottom, margins.left, margins.right);
  const banded = widest > Math.min(margins.top, margins.bottom, margins.left, margins.right) * 2;
  if (!banded) {
    const x = block.x + block.w / 2,
      y = block.y + block.h / 2;
    const flat = { x, y, angle: 0, align: 'center' as const, room: block.w, band: block.h },
      upright = { ...flat, angle: -Math.PI / 2, room: block.h, band: block.w };
    return block.h > block.w * 1.6 ? [upright, flat] : [flat, upright];
  }
  if (widest === margins.top || widest === margins.bottom)
    return [
      {
        x: block.body.x,
        y:
          widest === margins.top
            ? block.y + margins.top / 2
            : block.y + block.h - margins.bottom / 2,
        angle: 0,
        align: 'left',
        room: block.body.w,
        band: widest,
      },
    ];
  return [
    widest === margins.left
      ? {
          x: block.x + margins.left / 2,
          y: block.body.y + block.body.h,
          angle: -Math.PI / 2,
          align: 'left',
          room: block.body.h,
          band: widest,
        }
      : {
          x: block.x + block.w - margins.right / 2,
          y: block.body.y,
          angle: Math.PI / 2,
          align: 'left',
          room: block.body.h,
          band: widest,
        },
  ];
}

/**
 * Draws a label at the first candidate where it fits, stepping down to a smaller size and
 * then two lines; a label that cannot fit is omitted rather than overflowing its block.
 */
export function drawLabel(
  ctx: CanvasRenderingContext2D,
  text: string,
  places: Placement[],
  size: number,
  font: (size: number) => string,
) {
  const attempts = places.flatMap((place) => [
    { place, size, lines: [text] },
    { place, size: size * 0.86, lines: [text] },
    { place, size: size * 0.86, lines: text.split(' ') },
  ]);
  const fit = attempts.find(({ place, size: px, lines }) => {
    ctx.font = font(px);
    return (
      place.band >= px * (lines.length * 1.15 + 0.1) &&
      lines.every((line) => ctx.measureText(line).width <= place.room - 2)
    );
  });
  ctx.font = font(size);
  if (!fit) return;
  ctx.save();
  ctx.font = font(fit.size);
  ctx.translate(fit.place.x, fit.place.y);
  ctx.rotate(fit.place.angle);
  ctx.textAlign = fit.place.align;
  ctx.textBaseline = 'middle';
  fit.lines.forEach((line, i) =>
    ctx.fillText(line, 0, 0.5 + (i - (fit.lines.length - 1) / 2) * fit.size * 1.15),
  );
  ctx.restore();
}
