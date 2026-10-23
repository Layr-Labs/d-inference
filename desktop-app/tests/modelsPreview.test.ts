// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Snapshot } from '../src/shared/contracts';
import { activeAutopilot, poolSnapshot } from './modelsFixtures';

async function preview(search: string) {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  const api = (await import('../src/renderer/preview')).previewAPI;
  return { api, state: () => api.read<Snapshot>('state') };
}
const autopilotModule = async (search = '?preview') => {
  window.history.replaceState({}, '', `/${search}`);
  vi.resetModules();
  return import('../src/renderer/previewAutopilot');
};
const ids = (snapshot: Snapshot, test: (model: Snapshot['models'][number]) => boolean) =>
  snapshot.models.filter(test).map((model) => model.id);

afterEach(() => vi.useRealTimers());

describe('preview Autopilot parameters', () => {
  it('runs Autopilot by default with a mixed pool', async () => {
    const snapshot = await (await preview('?preview')).state();
    expect(snapshot.autopilot).toMatchObject({ enabled: true, paused: false, phase: 'active' });
    const pool = snapshot.autopilot!.selected;
    expect(pool).toEqual(['gpt-oss-20b', 'gemma-4-26b', 'qwen-3.5-9b']);
    expect(snapshot.autopilot!.pinned).toEqual(['gemma-4-26b']);
    expect(ids(snapshot, (model) => model.loaded)).toEqual(['gpt-oss-20b', 'gemma-4-26b']);
    expect(pool.filter((id) => !ids(snapshot, (model) => model.loaded).includes(id))).toEqual([
      'qwen-3.5-9b',
    ]);
    expect(ids(snapshot, (model) => model.eligible && !model.downloaded).length).toBeGreaterThan(2);
    expect(ids(snapshot, (model) => !model.eligible)).toContain('kimi-k2.6');
  });

  it.each([
    ['shadow', { enabled: true, phase: 'shadow' }],
    ['off', { enabled: false, phase: 'off' }],
  ])('reports autopilot=%s', async (mode, expected) => {
    const snapshot = await (await preview(`?preview&autopilot=${mode}`)).state();
    expect(snapshot.autopilot).toMatchObject(expected);
  });

  it('reports no Autopilot block and rejects its actions for autopilot=unsupported', async () => {
    const { api, state } = await preview('?preview&autopilot=unsupported');
    expect((await state()).autopilot).toBeUndefined();
    await expect(api.act({ action: 'autopilot_pause' })).rejects.toThrow('Unknown action');
  });
});

describe('preview Autopilot actions', () => {
  it('pins only pool models and refuses to remove a pinned one', async () => {
    const { api, state } = await preview('?preview');
    await expect(api.act({ action: 'autopilot_pin', models: ['qwen-3.6-35b'] })).rejects.toThrow(
      'Pins must be selected Autopilot models.',
    );
    await api.act({ action: 'autopilot_pin', models: ['qwen-3.5-9b'] });
    expect((await state()).autopilot!.pinned).toEqual(['gemma-4-26b', 'qwen-3.5-9b']);
    await expect(api.act({ action: 'remove', model: 'gemma-4-26b' })).rejects.toThrow(
      'Unpin this model first.',
    );
    await api.act({ action: 'autopilot_unpin', models: ['gemma-4-26b'] });
    await api.act({ action: 'remove', model: 'gemma-4-26b' });
    const after = await state();
    expect(after.autopilot!.selected).not.toContain('gemma-4-26b');
    expect(after.models.find((model) => model.id === 'gpt-oss-20b')!.memory_gb).toBe(16.4);
  });

  it('downloads with progress, then joins the pool on refresh', async () => {
    const { api, state } = await preview('?preview');
    vi.useFakeTimers();
    const started = await api.act({ action: 'download', model: 'qwen-3.6-35b' });
    expect(started).toMatchObject({ state: 'running', model: 'qwen-3.6-35b', progress: 0 });
    await vi.advanceTimersByTimeAsync(1000);
    const midway = (await state()).operations.find((item) => item.id === started.id)!;
    expect(midway.progress).toBeCloseTo(0.4);
    await vi.advanceTimersByTimeAsync(2000);
    const downloaded = await state();
    expect(downloaded.operations.find((item) => item.id === started.id)!.state).toBe('succeeded');
    expect(downloaded.autopilot!.selected).not.toContain('qwen-3.6-35b');
    const refresh = api.act({ action: 'autopilot_models' });
    await vi.advanceTimersByTimeAsync(1000);
    await refresh;
    expect((await state()).autopilot!.selected).toContain('qwen-3.6-35b');
  });

  it('pauses, resumes and turns off', async () => {
    const { api, state } = await preview('?preview&autopilot=shadow');
    await api.act({ action: 'autopilot_pause' });
    expect((await state()).autopilot).toMatchObject({ paused: true, phase: 'paused' });
    await api.act({ action: 'autopilot_resume' });
    expect((await state()).autopilot).toMatchObject({ paused: false, phase: 'shadow' });
    await api.act({ action: 'autopilot_disable' });
    expect((await state()).autopilot).toMatchObject({ enabled: false, phase: 'off' });
  });
});

describe('preview Autopilot decisions', () => {
  it('keeps pins loaded and rotates the one model in demand', async () => {
    const { autopilotStep } = await autopilotModule();
    const snapshot = poolSnapshot();
    const loaded = (turn: number) => ids(autopilotStep(snapshot, turn), (model) => model.loaded);
    expect(loaded(0)).toEqual(['gpt-oss-20b', 'gemma-4-26b']);
    expect(loaded(1)).toEqual(['gemma-4-26b', 'qwen-3.5-9b']);
    expect(autopilotStep(snapshot, 1).machine.models).toEqual(['gemma-4-26b', 'qwen-3.5-9b']);
  });

  it('never loads past the memory cap', async () => {
    const { autopilotStep } = await autopilotModule();
    const snapshot = poolSnapshot({}, { memory: { total_gb: 32, free_for_load_gb: 4 } });
    expect(ids(autopilotStep(snapshot, 0), (model) => model.loaded)).toEqual(['gemma-4-26b']);
  });

  it('changes nothing unless Autopilot is active and serving', async () => {
    const { autopilotStep } = await autopilotModule();
    for (const snapshot of [
      poolSnapshot({ phase: 'shadow' }),
      poolSnapshot({ paused: true, phase: 'paused' }),
      poolSnapshot({ enabled: false, phase: 'off' }),
      poolSnapshot({}, { state: 'stopped' }),
    ])
      expect(autopilotStep(snapshot, 1)).toBe(snapshot);
  });

  it('runs only while the preview state is watched', async () => {
    vi.useFakeTimers();
    const { autopilotTickMs, simulateAutopilot } = await autopilotModule();
    let snapshot = poolSnapshot({ selected: [...activeAutopilot.selected] });
    const store = { get: () => snapshot, set: vi.fn((next: Snapshot) => (snapshot = next)) };
    const stop = simulateAutopilot(store);
    await vi.advanceTimersByTimeAsync(autopilotTickMs);
    expect(store.set).toHaveBeenCalledOnce();
    stop();
    await vi.advanceTimersByTimeAsync(autopilotTickMs * 3);
    expect(store.set).toHaveBeenCalledOnce();
  });
});
