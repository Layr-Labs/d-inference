import type { Resource } from '../shared/contracts';

// The latest release when the dev server can't read production's: v0.10.11, published
// 2026-11-09.
const release = {
  version: '0.10.11',
  published_at: '2026-11-09T20:46:47Z',
  notes:
    'v0.10.11 - Your Mac first, faster pairs\n\nA Mac with a local API pauses Darkbloom while you use it and takes Darkbloom requests again 2 minutes after your last one.\n- Qwen 3.8 27B pairs decode with their speculative assistant.\n- Qwen and Gemma 4 tensor-parallel decode and prefill are faster.',
};

// Development preview only: resources the preview API serves unchanged. The network, the
// rankings and the latest release are replaced by production's public data when the dev server
// reaches it (previewNetwork.ts).
export function previewResources(): Partial<Record<Resource, unknown>> {
  return {
    network: {
      total_tokens: '646572000000',
      total_requests: '195820000',
      total_macs: 1143,
      provider_regions: [
        {
          region: 'California',
          country: 'United States',
          latitude: 37,
          longitude: -122,
          providers: 121,
        },
        {
          region: 'Texas',
          country: 'United States',
          latitude: 31,
          longitude: -99,
          providers: 50,
        },
        { region: 'Tokyo', country: 'Japan', latitude: 35, longitude: 139, providers: 45 },
        {
          region: 'England',
          country: 'United Kingdom',
          latitude: 51,
          longitude: 0,
          providers: 42,
        },
        { region: 'Berlin', country: 'Germany', latitude: 52, longitude: 13, providers: 29 },
        { region: 'Sydney', country: 'Australia', latitude: -33, longitude: 151, providers: 21 },
        { region: 'São Paulo', country: 'Brazil', latitude: -23, longitude: -46, providers: 17 },
        { region: 'Singapore', country: 'Singapore', latitude: 1, longitude: 103, providers: 30 },
      ],
    },
    cooling: {
      supported: true,
      enabled: true,
      mode: 'automatic',
      temperature: 52,
      fans: [
        { name: 'Left fan', rpm: 2480, max_rpm: 5200 },
        { name: 'Right fan', rpm: 2510, max_rpm: 5200 },
      ],
    },
    release,
    leaderboard: {
      metric: 'earnings',
      window: '24h',
      entries: [
        { rank: 1, name: 'northstar', earnings_micro_usd: '15647000', tokens: '2968200000' },
        { rank: 2, name: 'gumbii', earnings_micro_usd: '10134000', tokens: '2115000000' },
        { rank: 3, name: 'studio-north', earnings_micro_usd: '9698000', tokens: '1893400000' },
        { rank: 4, name: 'orchard', earnings_micro_usd: '8748000', tokens: '1572100000' },
        { rank: 5, name: 'xaden', earnings_micro_usd: '7421000', tokens: '1281500000' },
      ],
    },
    // As the runtime relays it: the latest release alone. The minimum version is the account's
    // (`cloud`).
    'release-history': { history: [{ ...release, active: true }] },
    'endpoint-key': { key: 'preview-key-not-a-credential' },
  };
}
