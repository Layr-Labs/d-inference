import type { Resource } from '../shared/contracts';

// Development preview only: resources the preview API serves unchanged. The network and
// rankings are replaced by production's public statistics when the dev server reaches them
// (previewNetwork.ts).
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
      mode: 'automatic',
      temperature: 52,
      fans: [
        { name: 'Left fan', rpm: 2480, max_rpm: 5200 },
        { name: 'Right fan', rpm: 2510, max_rpm: 5200 },
      ],
    },
    release: {
      version: '0.9.16',
      published_at: new Date().toISOString(),
      notes: 'Improved provider reliability and model management.',
    },
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
    'release-history': {
      minimum_provider_version: '0.9.15',
      observed_at: new Date().toISOString(),
      history: [
        {
          version: '0.9.16',
          published_at: '2026-10-02T12:00:00Z',
          active: true,
          notes:
            'Improved provider reliability and model management.\n- Recover more reliably after a dropped connection.\n- Keep model downloads separate from models in memory.',
        },
        {
          version: '0.9.15',
          published_at: '2026-09-28T12:00:00Z',
          active: true,
          notes:
            'Clearer activity and earnings.\n- Track requests by model.\n- Separate inference earnings from base rewards.',
        },
        {
          version: '0.9.14',
          published_at: '2026-09-20T12:00:00Z',
          active: false,
          notes: 'Earlier provider release. Upgrade to a supported version to receive requests.',
        },
      ],
    },
    'endpoint-key': { key: 'preview-key-not-a-credential' },
  };
}
