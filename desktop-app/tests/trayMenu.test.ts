import { expect, it, vi } from 'vitest';
import type { Snapshot } from '../src/shared/contracts';
import { previewAPI } from '../src/renderer/preview';
import { startableModels, trayMenuModel, trayMenuUpdater } from '../src/main/trayMenu';

async function snapshot(patch: Partial<Snapshot> = {}): Promise<Snapshot> {
  return { ...(await previewAPI.read<Snapshot>('state')), ...patch };
}

it('derives the label and actions from provider state', async () => {
  expect(trayMenuModel(undefined)).toEqual({
    status: 'Connecting',
    canStart: false,
    canStop: false,
    canRestart: false,
  });
  expect(trayMenuModel(await snapshot({ state: 'stopped', operations: [] }))).toEqual({
    status: 'stopped',
    canStart: true,
    canStop: false,
    canRestart: false,
  });
  expect(trayMenuModel(await snapshot({ state: 'running', operations: [] }))).toMatchObject({
    canStop: true,
    canRestart: true,
  });
  const busy = await snapshot({
    state: 'running',
    operations: [
      {
        id: 'op',
        action: 'download',
        state: 'running',
        started_at: 0,
        message: '',
        cancellable: true,
      },
    ],
  });
  expect(trayMenuModel(busy)).toMatchObject({ canStop: false, canRestart: false });
});

it('rebuilds the native menu only when the visible menu changes', async () => {
  const render = vi.fn();
  const update = trayMenuUpdater(render);
  const running = await snapshot({ state: 'running', operations: [] });
  update(running);
  // Periodic snapshots (every ~2s) change telemetry, not the menu.
  update({ ...running, observed_at: running.observed_at + 2 });
  update({
    ...running,
    observed_at: running.observed_at + 4,
    activity: { ...running.activity, requests: '99' },
  });
  expect(render).toHaveBeenCalledTimes(1);
  update({ ...running, state: 'stopped' });
  expect(render).toHaveBeenCalledTimes(2);
  expect(render).toHaveBeenLastCalledWith(
    expect.objectContaining({ status: 'stopped', canStart: true }),
  );
});

it('starts the downloaded serving models from the latest snapshot', async () => {
  const state = await snapshot();
  expect(startableModels(undefined)).toEqual([]);
  expect(startableModels(state)).toEqual(
    state.models.filter((model) => model.serving && model.downloaded).map((model) => model.id),
  );
});
