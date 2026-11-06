export type Random = () => number;

/** mulberry32: small, fast and fully deterministic for a given 32-bit seed. */
export function seeded(seed: number): Random {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
export function hashString(value: string) {
  let hash = 2166136261;
  for (let i = 0; i < value.length; i++) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619);
  return hash >>> 0;
}
/** Stable pseudo-random value in [0, 1) for an integer key, for per-tile variation. */
export function noise(key: number) {
  const x = Math.sin(key * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
}
export function between(random: Random, min: number, max: number) {
  return min + (max - min) * random();
}
export function logNormal(random: Random, median: number, sigma: number) {
  const u = Math.max(random(), 1e-9),
    v = random();
  return median * Math.exp(sigma * Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v));
}
