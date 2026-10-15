import { between, type Random } from '../random';
import type { ChipCapability } from './capability';

/**
 * Synthetic request arrivals: a Poisson process whose rate drifts slowly, with occasional
 * bursts and idle gaps so the preview shows every state of the chip.
 */
export function createArrivals(random: Random, capability: ChipCapability, start: number) {
  const phaseA = random() * Math.PI * 2,
    phaseB = random() * Math.PI * 2;
  let burstAt = start + between(random, 2, 4),
    burstUntil = -1,
    burstRate = 0,
    idleAt = start + between(random, 35, 60),
    idleUntil = -1;
  return (time: number, step: number) => {
    if (time >= idleAt) {
      idleUntil = time + between(random, 6, 12);
      idleAt = idleUntil + between(random, 30, 70);
    }
    if (time >= burstAt) {
      const duration = between(random, 1, 1.6);
      burstRate = Math.round(between(random, 3, 6)) / duration;
      burstUntil = time + duration;
      burstAt = time + between(random, 22, 50);
    }
    const drift =
      0.65 +
      0.35 * Math.sin((time / 53) * Math.PI * 2 + phaseA) +
      0.2 * Math.sin(time / 2.7 + phaseB);
    const rate =
      time < idleUntil
        ? 0
        : capability.arrivalsPerSecond * Math.max(0.05, drift) +
          (time < burstUntil ? burstRate : 0);
    return random() < 1 - Math.exp(-rate * step) ? 1 : 0;
  };
}
