import type { Action, DesktopAPI, Snapshot, Resource } from '../shared/contracts';
import { previewInsights } from './previewInsights';

// Explicit development-only fixture. Never used as a fallback for failed live data.
const now = Date.now() / 1000;
let snapshot: Snapshot = {
  protocol: 1,
  version: '0.9.16',
  observed_at: now,
  installation_id: 'preview',
  linked: true,
  account_revision: 'preview-account',
  state: 'running',
  readiness: 'Connected and ready for requests',
  machine: {
    id: 'this-mac',
    name: 'MacBook Pro',
    chip: 'Apple M4 Max',
    memory_gb: 64,
    status: 'running',
    observed_at: now,
    version: '0.9.16',
    models: ['gpt-oss-20b'],
  },
  models: [
    {
      id: 'gpt-oss-20b',
      display_name: 'GPT-OSS 20B',
      size_gb: 12.1,
      memory_gb: 16.4,
      downloaded: true,
      serving: true,
      loaded: true,
      eligible: true,
      description: 'An open-weight reasoning model from OpenAI.',
      context_length: 131072,
      family: 'OpenAI',
      quantization: 'MXFP4',
    },
    {
      id: 'gemma-4-26b',
      display_name: 'Gemma 4 26B',
      size_gb: 15.6,
      memory_gb: 21.4,
      downloaded: true,
      serving: true,
      loaded: true,
      eligible: true,
      description: 'Versatile understanding, built for a wide range of tasks.',
      context_length: 131072,
      family: 'Google',
      quantization: '4-bit',
    },
    {
      id: 'qwen-3.5-9b',
      display_name: 'Qwen 3.5 9B',
      size_gb: 6.1,
      downloaded: false,
      serving: false,
      loaded: false,
      eligible: true,
      description: 'Compact, capable, and quick to respond.',
      context_length: 131072,
      family: 'Qwen',
      quantization: '4-bit',
    },
    {
      id: 'qwen-3.6-35b',
      display_name: 'Qwen 3.6 35B A3B',
      size_gb: 21.3,
      downloaded: false,
      serving: false,
      loaded: false,
      eligible: true,
      description: 'Efficient mixture-of-experts reasoning and coding.',
      context_length: 262144,
      family: 'Qwen',
      quantization: '4-bit',
    },
  ],
  operations: [],
  memory: { total_gb: 64, active_gb: 16.4, cache_gb: 3.4, free_for_load_gb: 34 },
  activity: {
    sampled_at: now,
    models: [
      { model: 'gpt-oss-20b', state: 'running', running: 18, waiting: 0 },
      { model: 'gemma-4-26b', state: 'running', running: 7, waiting: 1 },
    ],
    requests: '1203',
    tokens: '1290344',
    started_at: now - 86400,
    samples: Array.from({ length: 24 }, (_, i) => ({
      at: now - (23 - i) * 3600,
      requests: i * 45 + (i % 4) * 5,
      tokens: i * 45000,
    })),
  },
  settings: {
    revision: 'preview',
    name: 'MacBook Pro',
    auto_update: true,
    idle_minutes: 60,
    cache_path: '~/.cache/huggingface/hub',
  },
  endpoint: { base_url: 'http://127.0.0.1:8000/v1', authenticated: true, models: ['gpt-oss-20b'] },
};
const listeners = new Set<(state: Snapshot) => void>();
const cloud = {
  linked: true,
  account_id: 'preview',
  observed_at: now,
  lifetime_micro_usd: '2146200000',
  week_micro_usd: '46100000',
  balance_micro_usd: '146200000',
  machines: [
    {
      id: 'remote-studio',
      name: 'Mac Studio',
      chip: 'Apple M3 Ultra',
      memory_gb: 192,
      status: 'online',
      observed_at: now - 25,
      version: '0.9.16',
      models: ['gemma-4-26b'],
      earnings_micro_usd: '7000000',
    },
  ],
};
export const previewAPI: DesktopAPI = {
  async read<T>(resource: Resource) {
    snapshot.observed_at = Date.now() / 1000;
    snapshot.activity.sampled_at = snapshot.observed_at;
    const data: Record<Resource, unknown> = {
      'insights-week': previewInsights('7d'),
      'insights-month': previewInsights('30d'),
      state: structuredClone(snapshot),
      cloud,
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
    return data[resource] as T;
  },
  async act(action: Action) {
    if (action.action === 'stop')
      snapshot = { ...snapshot, state: 'stopped', readiness: 'Provider stopped' };
    if (action.action === 'start' || action.action === 'restart')
      snapshot = { ...snapshot, state: 'running', readiness: 'Connected and ready for requests' };
    if (action.action === 'download')
      snapshot.models = snapshot.models.map((model) =>
        model.id === action.model ? { ...model, downloaded: true } : model,
      );
    if (action.action === 'switch')
      snapshot.models = snapshot.models.map((model) => ({
        ...model,
        serving: action.models.includes(model.id),
        loaded: action.models.includes(model.id),
      }));
    if (action.action === 'settings') snapshot.settings = { ...snapshot.settings, ...action };
    const operation = {
      id: crypto.randomUUID(),
      action: action.action,
      state: 'succeeded' as const,
      started_at: Date.now() / 1000,
      message: 'Preview action complete',
      cancellable: false,
    };
    snapshot = { ...snapshot, operations: [operation, ...snapshot.operations].slice(0, 10) };
    listeners.forEach((fn) => fn(structuredClone(snapshot)));
    return operation;
  },
  async status() {
    return { state: 'ready' };
  },
  async install() {},
  async copy(text) {
    await navigator.clipboard.writeText(text);
  },
  async openExternal() {},
  async updateStatus() {
    return { state: 'idle' };
  },
  async checkUpdate() {
    return { state: 'idle' };
  },
  async applyUpdate() {},
  onState(callback) {
    listeners.add(callback);
    const timer = setInterval(() => {
      if (snapshot.state === 'running') {
        snapshot.activity.tokens = (BigInt(snapshot.activity.tokens || '0') + 324n).toString();
        snapshot.activity.requests = (BigInt(snapshot.activity.requests || '0') + 1n).toString();
        snapshot.activity.models = snapshot.activity.models?.map((model, index) => ({
          ...model,
          running: (index === 0 ? 15 : 6) + (Math.floor(Date.now() / 2000 + index) % 5),
        }));
      }
      snapshot.observed_at = Date.now() / 1000;
      snapshot.activity.sampled_at = snapshot.observed_at;
      callback(structuredClone(snapshot));
    }, 2000);
    return () => {
      clearInterval(timer);
      listeners.delete(callback);
    };
  },
  onStatus() {
    return () => {};
  },
  onNavigate() {
    return () => {};
  },
};
