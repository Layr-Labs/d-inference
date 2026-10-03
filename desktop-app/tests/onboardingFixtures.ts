import { vi } from 'vitest';
import type { NativeModel, Operation, Snapshot } from '../src/shared/contracts';
import type { BackendState } from '../src/renderer/useBackend';

export const models: NativeModel[] = [
  {
    id: 'gpt-oss-20b',
    display_name: 'GPT-OSS 20B',
    size_gb: 12.1,
    memory_gb: 16.4,
    downloaded: true,
    serving: false,
    loaded: false,
    eligible: true,
  },
  {
    id: 'qwen-3.5-9b',
    display_name: 'Qwen 3.5 9B',
    size_gb: 6.1,
    downloaded: false,
    serving: false,
    loaded: false,
    eligible: true,
  },
];

// A connected Mac that the derived checks find eligible: Apple silicon, and 64 GB against a
// smallest model that needs 16.4 GB.
export function snapshot(overrides: Partial<Snapshot> = {}): Snapshot {
  return {
    protocol: 1,
    version: '0.9.16',
    observed_at: 1_790_000_000,
    installation_id: 'test',
    linked: true,
    state: 'stopped',
    readiness: 'Ready when you are',
    machine: {
      id: 'this-mac',
      name: 'MacBook Pro',
      chip: 'Apple M4 Max',
      memory_gb: 64,
      status: 'stopped',
      models: [],
    },
    models,
    operations: [],
    memory: { total_gb: 64 },
    activity: { samples: [] },
    settings: {
      revision: 'r1',
      name: 'MacBook Pro',
      auto_update: true,
      idle_minutes: 60,
      cache_path: '~/.cache/huggingface/hub',
    },
    ...overrides,
  };
}

export const eightGBMac = (base = snapshot()) =>
  snapshot({
    machine: { ...base.machine, name: 'MacBook Air', chip: 'Apple M1', memory_gb: 8 },
    memory: { total_gb: 8 },
  });

export function backendWith(
  state: Snapshot | undefined,
  overrides: Partial<BackendState> = {},
): BackendState {
  return {
    status: { state: 'ready' },
    state,
    cloud: undefined,
    network: undefined,
    cooling: undefined,
    release: undefined,
    releaseHistory: undefined,
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn().mockResolvedValue(true),
    refresh: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  };
}

export const operation = (
  state: Operation['state'],
  message = '',
  action: Operation['action'] = 'waitlist',
): Operation => ({
  id: `${action}-operation`,
  action,
  state,
  started_at: 1_790_000_000,
  message,
  cancellable: false,
});
