import type { ModelTraffic } from './features/stats/data';
// Stats design fixture. Imported only by the explicit development preview path.

// Share of prompt tokens served from the prefix cache by local hour: agent sessions with long
// shared system prompts dominate working hours, one-off prompts dominate the night.
export const previewCacheShare = (at: number) => {
  const hour = new Date(at * 1000).getHours();
  return 0.22 + 0.46 * (0.5 - 0.5 * Math.cos(((hour - 5) / 24) * 2 * Math.PI));
};
export function previewStats(now: number): ModelTraffic[] {
  return [
    { id: 'gpt-oss-20b', name: 'GPT-OSS 20B', speed: 42, weight: 1 },
    { id: 'gemma-4-26b', name: 'Gemma 4 26B', speed: 61, weight: 0.58 },
  ].map((model, index) => {
    const points = Array.from({ length: 48 }, (_, i) => {
      const wave =
        22 + 14 * Math.sin(i * 0.22 + index) + 8 * Math.sin(i * 0.83 + 2) + (i > 28 ? 30 : 0);
      const requests = Math.max(2, Math.round(wave * model.weight));
      const at = now - (47 - i) * 1800;
      const prompt = requests * (2_150 + (i % 7) * 190 + index * 420);
      const cached = Math.round(prompt * Math.min(0.9, previewCacheShare(at) + index * 0.08));
      return {
        at,
        requests,
        tokens: requests * (780 + (i % 5) * 81),
        input: prompt - cached,
        cached,
      };
    });
    return {
      ...model,
      requests: points.reduce((sum, p) => sum + p.requests, 0),
      tokens: points.reduce((sum, p) => sum + p.tokens, 0),
      points,
    };
  });
}
