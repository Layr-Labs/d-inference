import { clamp } from '../geometry';
import { logNormal, type Random } from '../random';

/** One request in the continuous batch. */
export interface Sequence {
  model: number;
  prompt: number;
  prefilled: number;
  output: number;
  generated: number;
  stage: 'waiting' | 'prefill' | 'decode';
}

/** Prompt lengths are lognormal around ~900 tokens (200-4000); outputs around `outputMedian`. */
export function sampleSequence(random: Random, model: number, outputMedian: number): Sequence {
  return {
    model,
    prompt: Math.round(clamp(logNormal(random, 900, 0.75), 200, 4000)),
    prefilled: 0,
    output: Math.round(clamp(logNormal(random, outputMedian, 0.7), 40, 4000)),
    generated: 0,
    stage: 'waiting',
  };
}

/** Weighted pick favouring the first loaded model, as traffic usually does. */
export function pickModel(random: Random, models: number) {
  const weights = Array.from({ length: models }, (_, m) => 1 / (m + 1)),
    total = weights.reduce((sum, weight) => sum + weight, 0);
  let pick = random() * total;
  return Math.max(
    0,
    weights.findIndex((weight) => (pick -= weight) < 0),
  );
}
