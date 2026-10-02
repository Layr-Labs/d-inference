import type { ModelTraffic } from './features/stats/data';
// Stats design fixture. Imported only by the explicit development preview path.
export function previewStats(now: number): ModelTraffic[] {
  return [
    { id: 'gpt-oss-20b', name: 'GPT-OSS 20B', speed: 42, weight: 1 },
    { id: 'gemma-4-26b', name: 'Gemma 4 26B', speed: 61, weight: 0.58 },
  ].map((model, index) => {
    const points = Array.from({ length: 48 }, (_, i) => {
      const wave =
        22 + 14 * Math.sin(i * 0.22 + index) + 8 * Math.sin(i * 0.83 + 2) + (i > 28 ? 30 : 0);
      const requests = Math.max(2, Math.round(wave * model.weight));
      return { at: now - (47 - i) * 1800, requests, tokens: requests * (780 + (i % 5) * 81) };
    });
    return {
      ...model,
      requests: points.reduce((sum, p) => sum + p.requests, 0),
      tokens: points.reduce((sum, p) => sum + p.tokens, 0),
      points,
    };
  });
}
