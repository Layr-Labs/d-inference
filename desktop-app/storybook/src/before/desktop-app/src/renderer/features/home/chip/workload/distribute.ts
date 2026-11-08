/** Splits a running total across models in proportion to observed per-model counts. */
export function distribute(target: number, byModel: number[], models: number) {
  const weights = Array.from({ length: models }, (_, m) => Math.max(0, byModel[m] ?? 0)),
    total = weights.reduce((sum, weight) => sum + weight, 0);
  if (!total) return weights.map((_, m) => (m === 0 ? target : 0));
  const exact = weights.map((weight) => (weight / total) * target),
    shares = exact.map(Math.floor);
  let left = target - shares.reduce((sum, share) => sum + share, 0);
  exact
    .map((value, m) => ({ m, rest: value - shares[m] }))
    .sort((a, b) => b.rest - a.rest || a.m - b.m)
    .forEach(({ m }) => {
      if (left-- > 0) shares[m]++;
    });
  return shares;
}
