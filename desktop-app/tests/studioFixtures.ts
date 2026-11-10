import type { Snapshot } from '../src/shared/contracts';
import type { LocalServing } from '../src/shared/localServing';
import { poolSnapshot } from './modelsFixtures';

export const localCapabilities = ['local_serving', 'tool_setup', 'update_rollback'];

// A runtime with local-first serving: Both, me first saved, its local API on 8001 serving the two
// loaded models, no route saved and no account key.
export function localSnapshot(
  local: Partial<LocalServing> = {},
  overrides: Partial<Snapshot> = {},
): Snapshot {
  return poolSnapshot(
    {},
    {
      capabilities: localCapabilities,
      activity: { started_at: 1_790_000_000, samples: [] },
      endpoint: {
        base_url: 'http://127.0.0.1:8001/v1',
        authenticated: true,
        models: ['gpt-oss-20b', 'gemma-4-26b'],
      },
      local: {
        mode: 'both',
        me_first: true,
        me_first_idle_minutes: 2,
        route: null,
        route_key: false,
        port: 8001,
        bind: '127.0.0.1',
        paused_until: null,
        ...local,
      },
      ...overrides,
    },
  );
}
