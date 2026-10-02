import type { Action, DesktopAPI, Snapshot, Resource } from '../shared/contracts';

// Explicit development-only fixture. Never used as a fallback for failed live data.
const now = Date.now() / 1000;
let snapshot: Snapshot = {
  protocol: 1,
  version: '0.9.16',
  observed_at: now,
  installation_id: 'preview',
  linked: true,
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
      serving: false,
      loaded: false,
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
  lifetime_micro_usd: '146200000',
  week_micro_usd: '19600000',
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
    const data: Record<Resource, unknown> = {
      state: structuredClone(snapshot),
      cloud,
      network: { total_tokens: '646572000000', total_requests: '195820000', total_macs: 1143 },
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
      leaderboard: [
        { rank: 1, name: 'northstar', tokens: '2968200000' },
        { rank: 2, name: 'gumbii', tokens: '2115000000' },
        { rank: 3, name: 'studio-north', tokens: '1893400000' },
        { rank: 4, name: 'orchard', tokens: '1572100000' },
        { rank: 5, name: 'xaden', tokens: '1281500000' },
      ],
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
    return () => listeners.delete(callback);
  },
  onStatus() {
    return () => {};
  },
  onNavigate() {
    return () => {};
  },
};
