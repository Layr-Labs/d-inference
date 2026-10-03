// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { AutoUpdateSwitch } from '../src/renderer/features/updates/AutoUpdateSwitch';
import { Updates } from '../src/renderer/features/Updates';
import {
  compareVersions,
  publishedVersions,
  releaseStatus,
} from '../src/renderer/features/updates/version';
import { ReleaseTimeline } from '../src/renderer/features/updates/ReleaseTimeline';
import { previewAPI } from '../src/renderer/preview';
import type { BackendState } from '../src/renderer/useBackend';
vi.mock('../src/renderer/useBackend', () => ({
  api: {
    updateStatus: async () => ({ state: 'unconfigured', message: 'No desktop feed configured.' }),
  },
}));
afterEach(cleanup);

it('does not disable automatic updates until confirmed; cancellation preserves the preference', () => {
  const change = vi.fn();
  render(<AutoUpdateSwitch checked onChange={change} />);
  fireEvent.click(screen.getByRole('switch'));
  expect(screen.getByRole('dialog')).toBeVisible();
  expect(change).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Keep enabled' }));
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  expect(change).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('switch'));
  fireEvent.click(screen.getByRole('button', { name: 'Turn off' }));
  expect(change).toHaveBeenCalledWith(false);
});
it('requires only published floors, never a newer release alone', () => {
  expect(releaseStatus('0.9.16', '0.9.17', '0.9.15')).toBe('available');
  expect(releaseStatus('0.9.14', '0.9.17', '0.9.15')).toBe('required');
  expect(releaseStatus('0.9.16', '0.9.16', undefined)).toBe('current');
  expect(releaseStatus('0.9.16', '0.9.16', '0.9.15', true)).toBe('retired');
  expect(releaseStatus('unknown', '0.9.16', '0.9.15')).toBe('unknown');
  expect(compareVersions('0.10.0', '0.9.16')).toBe(1);
  expect(compareVersions('0.9.16-rc.2', '0.9.16-rc.10')).toBe(-1);
  expect(compareVersions('0.9.16-rc.2', '0.9.16')).toBe(-1);
});

it('withholds a published version while its resource reports an error', () => {
  const release = { version: '0.9.17' };
  const releaseHistory = { minimum_provider_version: '0.9.15', history: [] };
  expect(publishedVersions({ release, releaseHistory })).toEqual({
    latest: '0.9.17',
    minimum: '0.9.15',
  });
  expect(
    publishedVersions({
      release: { ...release, error: 'offline' },
      releaseHistory: { ...releaseHistory, error: 'offline' },
    }),
  ).toEqual({ latest: undefined, minimum: undefined });
  expect(publishedVersions({})).toEqual({ latest: undefined, minimum: undefined });
});
it('uses revision-checked native settings and never restarts the provider automatically', async () => {
  const state = await previewAPI.read<NonNullable<BackendState['state']>>('state');
  state.settings.startup_preload = true;
  const backend: BackendState = {
    state,
    status: { state: 'ready' },
    cloud: undefined,
    network: undefined,
    cooling: undefined,
    release: { version: '0.9.17' },
    releaseHistory: { minimum_provider_version: '0.9.15', history: [] },
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn().mockResolvedValue(true),
    refresh: vi.fn(),
  };
  render(<Updates backend={backend} />);
  fireEvent.click(screen.getByRole('switch'));
  fireEvent.click(screen.getByRole('button', { name: 'Turn off' }));
  await waitFor(() => expect(backend.act).toHaveBeenCalledTimes(1));
  expect(backend.act).toHaveBeenCalledWith(
    expect.objectContaining({
      action: 'settings',
      revision: state.settings.revision,
      auto_update: false,
      name: state.settings.name,
    }),
    true,
  );
  expect(vi.mocked(backend.act).mock.calls[0][0]).not.toHaveProperty('startup_preload');
  expect(await screen.findByRole('button', { name: 'Restart provider' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Update now' })).toBeVisible();
});
it('keeps missing notes honest and explains old releases on the timeline', () => {
  render(
    <ReleaseTimeline
      installed="0.9.14"
      latest={{ version: '0.9.16' }}
      history={{
        minimum_provider_version: '0.9.15',
        history: [{ version: '0.9.14', notes: '', published_at: '', active: false }],
      }}
    />,
  );
  expect(screen.getByText('Retired')).toBeVisible();
  expect(screen.getByText('Installed')).toBeVisible();
  expect(screen.getByText('Release notes haven’t been published yet.')).toBeVisible();
});
