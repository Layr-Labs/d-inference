import { vi } from 'vitest';
import type { BackendState } from '../src/renderer/useBackend';
import { previewAPI } from '../src/renderer/preview';
import type { CloudData, CoolingData, Snapshot } from '../src/shared/contracts';

// A connected BackendState from the development preview fixture, with spy actions.
export async function previewBackend(overrides: Partial<BackendState> = {}): Promise<BackendState> {
  return {
    status: { state: 'ready' },
    state: await previewAPI.read<Snapshot>('state'),
    cloud: structuredClone(await previewAPI.read<CloudData>('cloud')),
    network: undefined,
    cooling: structuredClone(await previewAPI.read<CoolingData>('cooling')),
    release: undefined,
    releaseHistory: undefined,
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn().mockResolvedValue(true),
    refresh: vi.fn(),
    ...overrides,
  };
}
