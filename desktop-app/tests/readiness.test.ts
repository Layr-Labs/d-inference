import { expect, it } from 'vitest';
import { assessReadiness } from '../src/renderer/features/machines/overview/readiness';
import { previewAPI } from '../src/renderer/preview';
import type { DesktopStatus, Snapshot } from '../src/shared/contracts';

const connected: DesktopStatus = { state: 'ready' };
const current = { required: false, available: false };
const state = () => previewAPI.read<Snapshot>('state');
const assess = (snapshot: Snapshot, status = connected, update = current) =>
  assessReadiness({ status, state: snapshot, update });
const ids = (readiness: ReturnType<typeof assess>) => readiness.steps.map((step) => step.id);

it('is ready with no steps while linked models serve', async () => {
  expect(assess(await state())).toEqual({
    tone: 'ready',
    summary: 'Serving GPT-OSS 20B and Gemma 4 26B',
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
  expect(linking.steps[0].detail).toContain('ABCD-1234');
  expect(linking.steps[0].actions).toEqual([{ kind: 'link-page', label: 'Open link page' }]);
});

it('reports only the runtime while disconnected', async () => {
  const snapshot = await state();
  const reconnecting = assess(snapshot, { state: 'connecting' });
  expect(reconnecting.tone).toBe('pending');
  expect(reconnecting.steps).toEqual([expect.objectContaining({ id: 'runtime', actions: [] })]);
  const broken = assess(snapshot, {
    state: 'error',
    message: 'Update or repair the installation.',
  });
  expect(broken.tone).toBe('blocked');
  expect(broken.steps[0]).toMatchObject({
    detail: 'Update or repair the installation.',
    actions: [{ kind: 'install', label: 'Repair runtime' }],
  });
  expect(assess(snapshot, { state: 'missing' }).steps[0].actions).toEqual([
    { kind: 'install', label: 'Install runtime' },
  ]);
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
          label: 'Start providing',
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
  const restart = { kind: 'act', action: { action: 'restart' }, label: 'Restart provider' };
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
    expect.objectContaining({ id: 'operation', title: 'Start in progress', actions: [] }),
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
