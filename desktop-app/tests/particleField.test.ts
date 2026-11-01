import { expect, it } from 'vitest';
import { packetPosition } from '../src/renderer/features/stats/particleField';
it('keeps gathering, orbiting, and token emission spatially continuous', () => {
  for (const lane of [0, 1])
    for (let branch = 0; branch < 9; branch++) {
      for (const seam of [0.3, 0.52]) {
        const a = packetPosition(seam - 1e-7, lane, branch, 2),
          b = packetPosition(seam, lane, branch, 2);
        expect(Math.abs(a.x - b.x)).toBeLessThan(0.0001);
        expect(Math.abs(a.y - b.y)).toBeLessThan(0.0001);
      }
    }
});
it('keeps every strand finite throughout the choreography', () => {
  for (let step = 0; step <= 100; step++)
    for (const lane of [0, 1]) {
      const p = packetPosition(step / 100, lane, step % 9, step);
      expect(Number.isFinite(p.x) && Number.isFinite(p.y)).toBe(true);
      expect(p.energy).toBeGreaterThanOrEqual(0);
      expect(p.energy).toBeLessThanOrEqual(1);
    }
});
