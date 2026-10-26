import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';
import { contains, overlaps } from '../src/renderer/features/home/chip/geometry';
import { chipLayout } from '../src/renderer/features/home/chip/layout';
import { tileParts } from '../src/renderer/features/home/chip/photoreal/dieParts';
import { fitLayout } from '../src/renderer/features/home/chip/photoreal/layoutFit';
import { cellRuns } from '../src/renderer/features/home/chip/photoreal/memoryLight';
import {
  capacitorLayout,
  viaLayout,
} from '../src/renderer/features/home/chip/photoreal/substrateLayout';

const SIZE = { width: 900, height: 440 };
const CHIPS = ['Apple M1', 'Apple M3 Pro', 'Apple M4 Max', 'Apple M2 Ultra'];

describe('photoreal memory cell runs', () => {
  it('covers exactly the requested cells with at most three rectangles', () => {
    for (const cols of [1, 3, 4, 7])
      for (let from = 0; from < 30; from += 3)
        for (let to = from; to <= 40; to += 5) {
          const runs = cellRuns(from, to, cols),
            covered = runs.flatMap(({ first, last }) =>
              Array.from({ length: last - first + 1 }, (_, i) => first + i),
            );
          expect(covered).toEqual(Array.from({ length: to - from }, (_, i) => from + i));
          expect(runs.length).toBeLessThanOrEqual(3);
          for (const { first, last } of runs) {
            const spansRows = Math.floor(first / cols) !== Math.floor(last / cols);
            if (spansRows) {
              expect(first % cols).toBe(0);
              expect((last + 1) % cols).toBe(0);
            }
          }
        }
  });
});

describe.each(CHIPS)('%s photoreal geometry', (chip) => {
  const layout = chipLayout(chipAnatomy(chip, 64), SIZE);

  it('scales the layout about the canvas centre without losing parts', () => {
    const same = fitLayout(layout, 1);
    for (const [a, b] of [
      [same.substrate, layout.substrate],
      [same.tiles[0], layout.tiles[0]],
      [same.memory[0].cells.at(-1)!, layout.memory[0].cells.at(-1)!],
    ])
      for (const key of ['x', 'y', 'w', 'h'] as const) expect(a[key]).toBeCloseTo(b[key], 9);
    const fitted = fitLayout(layout, 0.9);
    expect(fitted.tiles).toHaveLength(layout.tiles.length);
    expect(fitted.memory.map((pkg) => pkg.cells.length)).toEqual(
      layout.memory.map((pkg) => pkg.cells.length),
    );
    expect(fitted.unit).toBeCloseTo(layout.unit * 0.9);
    expect(contains(layout.substrate, fitted.substrate)).toBe(true);
    expect(fitted.substrate.x + fitted.substrate.w / 2).toBeCloseTo(SIZE.width / 2);
  });

  it('places capacitors and vias on open substrate only, deterministically', () => {
    const caps = capacitorLayout(layout);
    expect(caps.length).toBeGreaterThan(0);
    expect(capacitorLayout(layout)).toEqual(caps);
    for (const cap of caps) {
      expect(contains(layout.substrate, cap)).toBe(true);
      for (const part of [...layout.dies, ...layout.memory])
        expect(overlaps(part, cap)).toBe(false);
    }
    const vias = viaLayout(layout, caps);
    expect(viaLayout(layout, caps)).toEqual(vias);
    for (const via of vias) expect(contains(layout.substrate, { ...via, w: 0, h: 0 })).toBe(true);
  });

  it('keeps every core part inside its tile', () => {
    for (const tile of layout.tiles)
      for (const part of tileParts(tile)) expect(contains(tile, part, 1e-3)).toBe(true);
  });
});
