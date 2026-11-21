import type { ActivitySample, CloudData, Snapshot } from '../shared/contracts';
import { previewRemoteActivity } from './previewActivity';
import { previewTopology } from './previewHardware';

// Development preview only. This Mac is the machine the hardware fixture measures, so the
// snapshot, the chip drawing and the onboarding scan all describe the same Mac.
const chip = previewTopology.chip;
const memoryGb = previewTopology.memory.total_gb;

export function previewSnapshot(now: number, samples: ActivitySample[]): Snapshot {
  return {
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
      chip,
      memory_gb: memoryGb,
      status: 'running',
      observed_at: now,
      version: '0.9.16',
      models: ['gpt-oss-20b', 'gemma-4-26b'],
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
    memory: { total_gb: memoryGb, active_gb: 16.4, cache_gb: 3.4, free_for_load_gb: 34 },
    activity: {
      sampled_at: now,
      models: [
        { model: 'gpt-oss-20b', state: 'running', running: 18, waiting: 0 },
        { model: 'gemma-4-26b', state: 'running', running: 7, waiting: 1 },
      ],
      requests: String(samples.at(-1)!.requests),
      tokens: String(samples.at(-1)!.tokens),
      started_at: now - 30 * 3600,
      samples,
    },
    settings: {
      revision: 'preview',
      name: 'MacBook Pro',
      auto_update: true,
      idle_minutes: 60,
      cache_path: '~/.cache/huggingface/hub',
    },
    endpoint: {
      base_url: 'http://127.0.0.1:8000/v1',
      authenticated: true,
      models: ['gpt-oss-20b'],
    },
  };
}

export function previewCloud(now: number): CloudData {
  return {
    linked: true,
    account_id: 'preview',
    observed_at: now,
    lifetime_micro_usd: '2146200000',
    week_micro_usd: '46100000',
    balance_micro_usd: '146200000',
    local_earnings_micro_usd: '39100000',
    local_lifetime_micro_usd: '95400000',
    local_day_micro_usd: '5620000',
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
        lifetime_micro_usd: '186400000',
        day_micro_usd: '4120000',
        ...previewRemoteActivity(now),
      },
    ],
  };
}
