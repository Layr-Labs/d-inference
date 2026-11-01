import type { AutopilotStatus } from '../src/shared/autopilot';
import type { NativeModel, Operation, Snapshot } from '../src/shared/contracts';
import { snapshot } from './onboardingFixtures';

const model = (overrides: Partial<NativeModel> & Pick<NativeModel, 'id' | 'display_name'>) => ({
  size_gb: 10,
  downloaded: false,
  serving: false,
  loaded: false,
  eligible: true,
  ...overrides,
});

// Two models loaded (one of them pinned), one in the pool but not loaded, one not downloaded
// and one this Mac can't run.
export const poolModels: NativeModel[] = [
  model({
    id: 'gpt-oss-20b',
    display_name: 'GPT-OSS 20B',
    size_gb: 12.1,
    memory_gb: 16.4,
    downloaded: true,
    serving: true,
    loaded: true,
  }),
  model({
    id: 'gemma-4-26b',
    display_name: 'Gemma 4 26B',
    size_gb: 15.6,
    memory_gb: 21.4,
    downloaded: true,
    serving: true,
    loaded: true,
  }),
  model({
    id: 'qwen-3.5-9b',
    display_name: 'Qwen 3.5 9B',
    size_gb: 6.1,
    memory_gb: 7.2,
    downloaded: true,
  }),
  model({ id: 'qwen-3.6-35b', display_name: 'Qwen 3.6 35B A3B', size_gb: 21.3 }),
  model({
    id: 'kimi-k2.6',
    display_name: 'Kimi K2.6',
    size_gb: 380,
    eligible: false,
    reason: 'Needs 512 GB of unified memory.',
  }),
];

export const activeAutopilot: AutopilotStatus = {
  enabled: true,
  paused: false,
  selected: ['gpt-oss-20b', 'gemma-4-26b', 'qwen-3.5-9b'],
  pinned: ['gemma-4-26b'],
  phase: 'active',
};

export function poolSnapshot(
  autopilot: Partial<AutopilotStatus> | null = {},
  overrides: Partial<Snapshot> = {},
): Snapshot {
  return snapshot({
    state: 'running',
    models: poolModels,
    memory: { total_gb: 64, active_gb: 37.8, free_for_load_gb: 20 },
    autopilot: autopilot ? { ...activeAutopilot, ...autopilot } : undefined,
    ...overrides,
  });
}

export const succeeded = (action: Operation['action']): Operation => ({
  id: `${action}-done`,
  action,
  state: 'succeeded',
  started_at: 1_790_000_000,
  message: '',
  cancellable: false,
});
