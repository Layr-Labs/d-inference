import { describe, expect, it } from 'vitest';
import {
  inFilter,
  modelsMode,
  phaseCopy,
  poolState,
  runningDownload,
} from '../src/renderer/features/models/pool';
import { modelName } from '../src/renderer/models/facts';
import { activeAutopilot, poolModels, poolSnapshot, succeeded } from './modelsFixtures';

const byId = (id: string) => poolModels.find((model) => model.id === id)!;

describe('model names', () => {
  it('uses the catalog display name and falls back to the id', () => {
    expect(modelName(poolModels, 'gpt-oss-20b')).toBe(byId('gpt-oss-20b').display_name);
    expect(modelName(poolModels, 'unlisted/model')).toBe('unlisted/model');
  });
});

describe('models page mode', () => {
  it('runs Autopilot only when the runtime reports it enabled', () => {
    expect(modelsMode(poolSnapshot())).toBe('autopilot');
    expect(modelsMode(poolSnapshot({ enabled: false }))).toBe('manual');
    expect(modelsMode(poolSnapshot(null))).toBe('unsupported');
  });
});

describe('pool state', () => {
  it('derives each row state from the catalog and the Autopilot status', () => {
    const state = (id: string, downloading = false) =>
      poolState(byId(id), activeAutopilot, downloading);
    expect(state('kimi-k2.6')).toBe('ineligible');
    expect(state('qwen-3.6-35b')).toBe('available');
    expect(state('qwen-3.6-35b', true)).toBe('downloading');
    expect(state('qwen-3.5-9b')).toBe('pool');
    expect(state('gpt-oss-20b')).toBe('loaded');
    expect(state('gemma-4-26b')).toBe('pinned');
  });

  it('keeps a downloaded model outside the pool until the pool is refreshed', () => {
    const status = { ...activeAutopilot, selected: ['gpt-oss-20b'] };
    expect(poolState(byId('qwen-3.5-9b'), status, false)).toBe('outside');
  });

  it('groups states into filters', () => {
    expect(inFilter('outside', 'all')).toBe(true);
    expect(inFilter('loaded', 'pool')).toBe(true);
    expect(inFilter('outside', 'pool')).toBe(false);
    expect(inFilter('pinned', 'pinned')).toBe(true);
    expect(inFilter('loaded', 'pinned')).toBe(false);
    expect(inFilter('downloading', 'available')).toBe(true);
    expect(inFilter('ineligible', 'available')).toBe(false);
  });

  it('attributes a running download by its model, or by the operation this page started', () => {
    const running = { ...succeeded('download'), state: 'running' as const };
    const reported = poolSnapshot({}, { operations: [{ ...running, model: 'qwen-3.6-35b' }] });
    expect(runningDownload(reported, 'qwen-3.6-35b', {})).toBeDefined();
    expect(runningDownload(reported, 'qwen-3.5-9b', {})).toBeUndefined();
    const anonymous = poolSnapshot({}, { operations: [running] });
    expect(runningDownload(anonymous, 'qwen-3.6-35b', {})).toBeUndefined();
    expect(
      runningDownload(anonymous, 'qwen-3.6-35b', { [running.id]: 'qwen-3.6-35b' }),
    ).toBeDefined();
  });
});

describe('phase copy', () => {
  it('only claims to change models in the active phases', () => {
    expect(phaseCopy(activeAutopilot, true)).toEqual({ label: 'On', tone: 'online' });
    for (const phase of ['shadow', 'waiting', 'waiting_inventory', 'recovering'] as const)
      expect(phaseCopy({ ...activeAutopilot, phase }, true).detail).toMatch(
        /stay as they are|reconciling/,
      );
    expect(phaseCopy({ ...activeAutopilot, phase: 'shadow' }, true).detail).toMatch(
      /^Autopilot is learning; models stay as they are for now\./,
    );
  });

  it('treats a paused flag as paused whatever the phase says', () => {
    expect(phaseCopy({ ...activeAutopilot, paused: true }, true).label).toBe('Paused');
  });

  it('asks for a pool refresh only while waiting for inventory', () => {
    expect(phaseCopy({ ...activeAutopilot, phase: 'waiting_inventory' }, true).refresh).toBe(true);
    expect(phaseCopy(activeAutopilot, true).refresh).toBeUndefined();
  });

  it('distinguishes a runtime that hasn’t reported yet from a stopped Mac', () => {
    const unreported = { ...activeAutopilot, phase: undefined };
    expect(phaseCopy(unreported, true).label).toBe('Starting');
    expect(phaseCopy(unreported, false).label).toBe('Ready');
  });
});
