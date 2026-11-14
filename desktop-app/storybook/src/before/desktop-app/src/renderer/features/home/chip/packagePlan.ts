import type { ChipTier } from './anatomy';
import type { Orientation, Rect, Side } from './geometry';

/** Substrate margin around dies and memory, in die-edge units. */
export const PACKAGE_MARGIN = 0.115;
const TRACE_GAP = 0.085,
  PACKAGE_GAP = 0.06,
  SEAM = 0.035;

export interface PackagePlan {
  width: number;
  height: number;
  dies: { rect: Rect; orientation: Orientation }[];
  /** `side` is the die edge each memory package faces. */
  packages: { rect: Rect; side: Side }[];
}

/** Package arrangement in die-edge units, following Apple's conventions for each tier. */
export function packagePlan(tier: ChipTier): PackagePlan {
  const along = (1 - PACKAGE_GAP) / 2,
    depth = 0.3;
  if (tier === 'ultra') {
    // Two mirrored dies joined at the seam, turned a quarter so memory sits above and below.
    const top = depth + TRACE_GAP,
      bottom = top + 1 + TRACE_GAP;
    const dies = [0, 1].map((i) => ({
      rect: { x: i * (1 + SEAM), y: top, w: 1, h: 1 },
      orientation: (i === 0 ? 'cw' : 'ccw') as Orientation,
    }));
    const columns = dies.flatMap(({ rect }) =>
      [0, 1].map((j) => rect.x + j * (along + PACKAGE_GAP)),
    );
    return {
      width: 2 + SEAM,
      height: bottom + depth,
      dies,
      packages: (['top', 'bottom'] as const).flatMap((side) =>
        columns.map((x) => ({
          rect: { x, y: side === 'top' ? 0 : bottom, w: along, h: depth },
          side,
        })),
      ),
    };
  }
  if (tier === 'base') {
    const dieWidth = 1.18;
    return {
      width: dieWidth + TRACE_GAP + depth,
      height: 1,
      dies: [{ rect: { x: 0, y: 0, w: dieWidth, h: 1 }, orientation: 'none' }],
      packages: [0, 1].map((j) => ({
        rect: { x: dieWidth + TRACE_GAP, y: j * (along + PACKAGE_GAP), w: depth, h: along },
        side: 'right' as const,
      })),
    };
  }
  const single = tier === 'pro',
    packageDepth = single ? 0.34 : depth,
    packageLength = single ? 0.86 : along,
    dieWidth = single ? 1.12 : 1,
    dieX = packageDepth + TRACE_GAP;
  const ys = single ? [(1 - packageLength) / 2] : [0, along + PACKAGE_GAP];
  return {
    width: 2 * dieX + dieWidth,
    height: 1,
    dies: [{ rect: { x: dieX, y: 0, w: dieWidth, h: 1 }, orientation: 'none' }],
    packages: (['left', 'right'] as const).flatMap((side) =>
      ys.map((y) => ({
        rect: {
          x: side === 'left' ? 0 : dieX + dieWidth + TRACE_GAP,
          y,
          w: packageDepth,
          h: packageLength,
        },
        side,
      })),
    ),
  };
}
