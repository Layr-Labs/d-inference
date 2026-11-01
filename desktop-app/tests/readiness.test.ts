import { describe, expect, it } from 'vitest';
import { assessReadiness } from '../src/renderer/features/machines/overview/readiness';
import { previewAPI } from '../src/renderer/preview';
import type { DesktopStatus, Snapshot } from '../src/shared/contracts';

const connected: DesktopStatus = { state: 'ready' };
const current = { required: false, available: false };
const state = () => previewAPI.read<Snapshot>('state');
const assess = (snapshot: Snapshot, status = connected, update = current, macosVersion = '27.0') =>
  assessReadiness({ status, state: snapshot, update, macosVersion });
const ids = (readiness: ReturnType<typeof assess>) => readiness.steps.map((step) => step.id);

it('is ready with no steps while linked models serve', async () => {
  expect(assess(await state())).toEqual({
    tone: 'ready',
    status: 'Ready to serve',
    summary: '2 models loaded',
    steps: [],
  });
});

it('advises linking without changing a ready tone', async () => {
  const readiness = assess({ ...(await state()), linked: false });
  expect(readiness.tone).toBe('ready');
  expect(readiness.steps).toEqual([
    expect.objectContaining({
      id: 'link',
      actions: [{ kind: 'act', action: { action: 'link' }, label: 'Link account' }],
    }),
  ]);
  const linking = assess({
    ...(await state()),
    linked: false,
    link: {
      url: 'https://console.darkbloom.dev/link',
      code: 'ABCD-1234',
      expires_at: 1,
      state: 'pending',
    },
  });
  expect(linking.steps[0].code).toBe('ABCD-1234');
  expect(linking.steps[0].actions).toEqual([{ kind: 'link-page', label: 'Open link page' }]);
});

it('reports only the CLI while disconnected', async () => {
  const snapshot = await state();
  const reconnecting = assess(snapshot, { state: 'connecting' });
  expect(reconnecting.tone).toBe('pending');
  expect(reconnecting.steps).toEqual([
    expect.objectContaining({
      id: 'runtime',
      title: 'Reconnecting to the Darkbloom CLI',
      actions: [],
    }),
  ]);
  expect(assess(snapshot, { state: 'installing' }).steps[0].title).toBe(
    'Installing the Darkbloom CLI',
  );
  const broken = assess(snapshot, {
    state: 'error',
    message: 'Update or repair the installation.',
  });
  expect(broken.tone).toBe('blocked');
  expect(broken.steps[0]).toMatchObject({
    title: 'Repair the Darkbloom CLI',
    detail: 'Update or repair the installation.',
    actions: [{ kind: 'install', label: 'Repair CLI' }],
  });
  expect(assess(snapshot, { state: 'missing' }).steps[0]).toMatchObject({
    title: 'Install the Darkbloom CLI',
    detail: 'The app can’t reach the Darkbloom CLI on this Mac.',
    actions: [{ kind: 'install', label: 'Install CLI' }],
  });
  // Nothing is said about macOS while the CLI itself is unavailable.
  expect(ids(assess(snapshot, { state: 'missing' }, current, '26.5'))).toEqual(['runtime']);
});

it('offers to start a stopped provider with its selected downloaded models', async () => {
  const readiness = assess({ ...(await state()), state: 'stopped' });
  expect(readiness.tone).toBe('blocked');
  expect(readiness.summary).toBe('Not serving requests');
  expect(readiness.steps).toEqual([
    expect.objectContaining({
      id: 'start',
      actions: [
        {
          kind: 'act',
          action: { action: 'start', models: ['gpt-oss-20b', 'gemma-4-26b'] },
          label: 'Start serving',
        },
        { kind: 'route', route: 'models', label: 'Choose models' },
      ],
    }),
  ]);
});

it('sends a Mac without usable models to Models', async () => {
  const snapshot = await state();
  const unselected = snapshot.models.map((model) => ({ ...model, serving: false }));
  expect(ids(assess({ ...snapshot, state: 'stopped', models: unselected }))).toEqual(['choose']);
  expect(ids(assess({ ...snapshot, models: unselected }))).toEqual(['choose']);
  const empty = snapshot.models.map((model) => ({ ...model, downloaded: false }));
  expect(assess({ ...snapshot, models: empty }).steps[0]).toMatchObject({
    id: 'download',
    actions: [{ kind: 'route', route: 'models', label: 'Browse models' }],
  });
});

it('waits for loading, draining and starting without offering actions', async () => {
  const snapshot = await state();
  const unloaded = snapshot.models.map((model) => ({ ...model, loaded: false }));
  for (const [readiness, id] of [
    [assess({ ...snapshot, models: unloaded }), 'loading'],
    [assess({ ...snapshot, state: 'draining' }), 'draining'],
    [assess({ ...snapshot, state: 'starting' }), 'starting'],
  ] as const) {
    expect(readiness.tone).toBe('pending');
    expect(readiness.summary).toBe('Not serving new requests');
    expect(readiness.steps).toEqual([expect.objectContaining({ id, actions: [] })]);
  }
});

it('offers a restart for a stale snapshot or a crashed model', async () => {
  const snapshot = await state();
  const restart = { kind: 'act', action: { action: 'restart' }, label: 'Restart serving' };
  expect(assess({ ...snapshot, state: 'stale' }).steps[0]).toMatchObject({
    id: 'stale',
    actions: [restart],
  });
  const crashed = assess({
    ...snapshot,
    activity: {
      ...snapshot.activity,
      models: [{ model: 'gemma-4-26b', state: 'crashed', running: 0, waiting: 0 }],
    },
  });
  expect(crashed.tone).toBe('blocked');
  expect(crashed.steps[0]).toMatchObject({
    id: 'crashed',
    detail: 'Gemma 4 26B stopped unexpectedly.',
    actions: [restart],
  });
});

it('puts a running operation first and holds provider steps during lifecycle changes', async () => {
  const snapshot = await state();
  const operation = (action: 'start' | 'download') => ({
    id: action,
    action,
    state: 'running' as const,
    started_at: 1,
    message: '',
    cancellable: false,
  });
  const starting = assess({ ...snapshot, state: 'stopped', operations: [operation('start')] });
  expect(starting.tone).toBe('pending');
  expect(starting.steps).toEqual([
    expect.objectContaining({ id: 'operation', title: 'Starting to serve', actions: [] }),
  ]);
  const downloading = assess({
    ...snapshot,
    state: 'stopped',
    operations: [operation('download')],
  });
  expect(downloading.tone).toBe('blocked');
  expect(ids(downloading)).toEqual(['operation', 'start']);
  expect(ids(assess({ ...snapshot, operations: [operation('download')] }))).toEqual([]);
});

it('requires an update the routing floor rejects and offers it only when compatible', async () => {
  const snapshot = await state();
  const available = assess(snapshot, connected, { required: true, available: true });
  expect(available.tone).toBe('blocked');
  expect(available.steps[0].actions).toEqual([
    { kind: 'act', action: { action: 'update' }, label: 'Update now' },
  ]);
  const unavailable = assess(snapshot, connected, { required: true, available: false });
  expect(unavailable.steps[0]).toMatchObject({ id: 'update', actions: [] });
});

it('waits for a running update instead of offering the required update again', async () => {
  const snapshot = await state();
  const updating = assess(
    {
      ...snapshot,
      operations: [
        {
          id: 'update',
          action: 'update',
          state: 'running',
          started_at: 1,
          message: '',
          cancellable: false,
        },
      ],
    },
    connected,
    { required: true, available: true },
  );
  expect(updating).toMatchObject({ tone: 'pending', status: 'Updating Darkbloom' });
  expect(updating.steps).toEqual([
    expect.objectContaining({ id: 'operation', title: 'Updating Darkbloom', actions: [] }),
  ]);
});

it('uses current facts instead of authorization event text or processing counts', async () => {
  const snapshot = {
    ...(await state()),
    readiness: 'Provider authorization updated',
    provider_status: 'online',
  };
  const ready = assess(snapshot);
  expect(ready.status).toBe('Ready to serve');
  expect(ready.summary).toBe('2 models loaded');
  const unloaded = snapshot.models.map((model) => ({ ...model, loaded: false }));
  expect(assess({ ...snapshot, models: unloaded }).status).toBe('Loading models');
  expect(assess({ ...snapshot, provider_status: 'untrusted' })).toMatchObject({
    tone: 'blocked',
    status: 'Verification needed',
  });
  expect(assess({ ...snapshot, provider_status: 'offline' })).toMatchObject({
    tone: 'pending',
    status: 'Connecting to the network',
  });
  expect(assess({ ...snapshot, state: 'stale' }).status).toBe('Status unavailable');
  expect(assess({ ...snapshot, state: 'stopped' }).status).toBe('Stopped');
  expect(
    assess({
      ...snapshot,
      models: snapshot.models.map((model, i) => ({ ...model, loaded: i === 0 })),
    }).summary,
  ).toBe('1 model loaded');
});

describe('macOS below the minimum for new providers', () => {
  const below = (snapshot: Snapshot, update = current) =>
    assess(snapshot, connected, update, '26.5');
  const macos = {
    id: 'macos',
    title: 'Update macOS',
    detail: 'Darkbloom needs macOS 27 or later. Update macOS to keep serving.',
    actions: [{ kind: 'software-update', label: 'Open Software Update' }],
  };

  it('advises updating macOS on an existing install without blocking a serving Mac', async () => {
    expect(below(await state())).toEqual({
      tone: 'ready',
      status: 'Ready to serve',
      summary: '2 models loaded',
      steps: [macos],
    });
  });

  it('comes after the steps that keep this Mac from serving, before linking', async () => {
    const stopped = below({ ...(await state()), state: 'stopped', linked: false });
    expect(stopped).toMatchObject({ tone: 'blocked', status: 'Stopped' });
    expect(ids(stopped)).toEqual(['start', 'macos', 'link']);
    const required = below(await state(), { required: true, available: true });
    expect(required.status).toBe('Update Darkbloom');
    expect(ids(required)).toEqual(['update', 'macos']);
    const offline = below({ ...(await state()), provider_status: 'offline' });
    expect(offline).toMatchObject({ tone: 'pending', status: 'Connecting to the network' });
    expect(ids(offline)).toEqual(['connection', 'macos']);
  });

  it('says nothing on macOS 27 or later, or when the version is unknown', async () => {
    for (const version of ['27.0', '27.1.2', '28.0', '', undefined])
      expect(
        assessReadiness({
          status: connected,
          state: await state(),
          update: current,
          macosVersion: version,
        }).steps,
      ).toEqual([]);
  });
});
