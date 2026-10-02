import { percent } from './types';
export const TOKEN_MILESTONES = [
  100_000n,
  1_000_000n,
  10_000_000n,
  100_000_000n,
  1_000_000_000n,
  10_000_000_000n,
  100_000_000_000n,
  1_000_000_000_000n,
];
export function tokenProgress(tokens: bigint) {
  const achieved = TOKEN_MILESTONES.filter((target) => tokens >= target);
  const next = TOKEN_MILESTONES.find((target) => tokens < target) ?? null;
  const previous = achieved.at(-1) ?? 0n;
  return {
    achieved,
    next,
    previous,
    progress: next === null ? 100 : percent(tokens - previous, next - previous),
  };
}
