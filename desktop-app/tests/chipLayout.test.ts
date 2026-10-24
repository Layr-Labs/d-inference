import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';
import { contains, overlaps, type Rect } from '../src/renderer/features/home/chip/geometry';
import { chipLayout } from '../src/renderer/features/home/chip/layout';

const CHIPS = ['Apple M1', 'Apple M2 Pro', 'Apple M4 Max', 'Apple M3 Ultra', 'Unknown silicon'];
const SIZES = [
  { width: 900, height: 420 },
  { width: 640, height: 480 },
  { width: 380, height: 300 },
];
const pairs = <T>(items: T[]) => items.flatMap((a, i) => items.slice(i + 1).map((b) => [a, b]));

describe.each(CHIPS)('%s layout', (chip) => {
  const anatomy = chipAnatomy(chip, 64);
  it.each(SIZES)('keeps counts and geometry invariants at $width x $height', (size) => {
    const layout = chipLayout(anatomy, size),
      canvas: Rect = { x: 0, y: 0, w: size.width, h: size.height };
    const counted = (kind: string) =>
      layout.tiles.filter((tile) => tile.kind === kind && !tile.filler).length;
    expect(counted('gpu')).toBe(anatomy.gpuCores);
    expect(counted('performance')).toBe(anatomy.performanceCores);
    expect(counted('efficiency')).toBe(anatomy.efficiencyCores);
    expect(counted('neural')).toBe(0);
    expect(layout.blocks.every((block) => ['cpu', 'gpu', 'interface'].includes(block.kind))).toBe(
      true,
    );
    expect(layout.dies).toHaveLength(anatomy.dies);
    expect(layout.memory).toHaveLength(anatomy.memoryPackages);

    expect(contains(canvas, layout.substrate)).toBe(true);
    for (const die of layout.dies) expect(contains(layout.substrate, die)).toBe(true);
    for (const pkg of layout.memory) {
      expect(contains(layout.substrate, pkg)).toBe(true);
      expect(pkg.cells).toHaveLength(pkg.cols * pkg.rows);
      for (const cell of pkg.cells) expect(contains(pkg, cell)).toBe(true);
      for (const die of layout.dies) expect(overlaps(pkg, die)).toBe(false);
      expect(layout.phy.some((segment) => segment.package === pkg.index)).toBe(true);
      expect(layout.traces.some((trace) => trace.package === pkg.index)).toBe(true);
    }
    for (const [a, b] of pairs(layout.memory)) expect(overlaps(a, b)).toBe(false);
    for (const [a, b] of pairs(layout.dies)) expect(overlaps(a, b)).toBe(false);

    for (const block of layout.blocks) {
      expect(contains(layout.dies[block.die], block)).toBe(true);
      expect(contains(block, block.body)).toBe(true);
    }
    for (const die of layout.dies)
      for (const [a, b] of pairs(layout.blocks.filter((block) => block.die === die.index)))
        expect(overlaps(a, b)).toBe(false);
    for (const tile of layout.tiles) {
      expect(
        layout.blocks.some((block) => block.die === tile.die && contains(block.body, tile)),
      ).toBe(true);
      expect(tile.dispatch).toBeGreaterThanOrEqual(0);
      expect(tile.dispatch).toBeLessThanOrEqual(1);
      expect(tile.memory).toBeGreaterThanOrEqual(0);
      expect(tile.memory).toBeLessThanOrEqual(1);
    }
    for (const [a, b] of pairs(layout.tiles)) expect(overlaps(a, b)).toBe(false);
    for (const trace of layout.traces) {
      expect(contains(layout.substrate, { ...trace.from, w: 0, h: 0 })).toBe(true);
      expect(
        contains(layout.dies[layout.memory[trace.package].die], { ...trace.to, w: 0, h: 0 }),
      ).toBe(true);
    }
  });

  it('is deterministic', () => {
    expect(chipLayout(anatomy, SIZES[0])).toEqual(chipLayout(anatomy, SIZES[0]));
  });
});

describe('package arrangement', () => {
  it('places memory beside base, Pro and Max dies and around both Ultra dies', () => {
    const sides = (chip: string) =>
      chipLayout(chipAnatomy(chip, 64), SIZES[0]).memory.map((pkg) => pkg.side);
    expect(sides('Apple M1')).toEqual(['right', 'right']);
    expect(sides('Apple M3 Pro')).toEqual(['left', 'right']);
    expect(sides('Apple M4 Max')).toEqual(['left', 'left', 'right', 'right']);
    expect(sides('Apple M2 Ultra')).toEqual([...Array(4).fill('top'), ...Array(4).fill('bottom')]);
    const ultra = chipLayout(chipAnatomy('Apple M2 Ultra', 192), SIZES[0]);
    expect(ultra.dies.map((die) => die.orientation)).toEqual(['cw', 'ccw']);
    expect(ultra.bridge).not.toBeNull();
  });
});
