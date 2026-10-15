import { describe, expect, it } from 'vitest';
import { methodFor, startAction } from '../src/renderer/components/onboarding/startPlan';
import { pinnedMemory, startingModel } from '../src/renderer/models/selection';
import { models, snapshot } from './onboardingFixtures';

const undownloaded = models.map((model) => ({ ...model, downloaded: false }));
// A model the scan found on disk that the catalog doesn't list, like a leftover Hugging Face
// copy. Its id sorts ahead of the catalog's lowercase ids.
const localOnly = {
  ...models[0],
  id: 'prism-ml/Ternary-Bonsai-2-27B-mlx-2bit',
  display_name: 'prism-ml/Ternary-Bonsai-2-27B-mlx-2bit',
  network: false,
};
const withLocalOnly = () => snapshot({ models: [localOnly, ...models] });

describe('starting model', () => {
  it('prefers an eligible model already on disk', () => {
    expect(startingModel(snapshot())?.id).toBe('gpt-oss-20b');
  });

  it('otherwise picks the smallest eligible download', () => {
    expect(startingModel(snapshot({ models: undownloaded }))?.id).toBe('qwen-3.5-9b');
  });

  it('never picks a model the network does not list', () => {
    expect(startingModel(withLocalOnly())?.id).toBe('gpt-oss-20b');
    expect(startingModel(snapshot({ models: [localOnly] }))).toBeUndefined();
  });

  it('never picks an ineligible model', () => {
    const none = models.map((model) => ({ ...model, eligible: false }));
    expect(startingModel(snapshot({ models: none }))).toBeUndefined();
  });
});

describe('start action', () => {
  it('maps each method onto its runtime action', () => {
    expect(methodFor(false)).toBe('autopilot');
    expect(methodFor(true)).toBe('manual');
  });

  it('starts Autopilot on the starting model unless models are pinned, with sorted pins', () => {
    expect(startAction(snapshot(), 'autopilot', [])).toEqual({
      action: 'autopilot',
      models: ['gpt-oss-20b'],
      pinned: [],
      endpoint: true,
    });
    expect(startAction(snapshot(), 'autopilot', ['qwen-3.5-9b', 'gpt-oss-20b'])).toEqual({
      action: 'autopilot',
      models: ['qwen-3.5-9b', 'gpt-oss-20b'],
      pinned: ['gpt-oss-20b', 'qwen-3.5-9b'],
      downloads: ['qwen-3.5-9b'],
      endpoint: true,
    });
  });

  it('drops pins found only on disk from onboarding starts, which always serve the network', () => {
    expect(startAction(withLocalOnly(), 'autopilot', [localOnly.id])).toEqual({
      action: 'autopilot',
      models: ['gpt-oss-20b'],
      pinned: [],
      endpoint: true,
    });
    expect(startAction(withLocalOnly(), 'manual', [localOnly.id, 'gpt-oss-20b'])).toMatchObject({
      models: ['gpt-oss-20b'],
    });
  });

  it('starts exactly the chosen models without Autopilot', () => {
    expect(startAction(snapshot(), 'manual', ['qwen-3.5-9b'])).toEqual({
      action: 'start',
      models: ['qwen-3.5-9b'],
      local: false,
      endpoint: true,
    });
  });
});

describe('pinned memory', () => {
  it('sums measured models and says when an unmeasured pin is missing', () => {
    expect(pinnedMemory(snapshot(), ['gpt-oss-20b'])).toEqual({
      needed: 16.4,
      measured: true,
      exceeds: false,
    });
    expect(pinnedMemory(snapshot(), ['gpt-oss-20b', 'qwen-3.5-9b']).measured).toBe(false);
    expect(pinnedMemory(snapshot({ memory: { total_gb: 16 } }), ['gpt-oss-20b']).exceeds).toBe(
      true,
    );
  });

  it('tells the slot limit apart from the memory budget', () => {
    const pins = ['gpt-oss-20b', 'qwen-3.5-9b'];
    expect(
      pinnedMemory(snapshot({ memory: { total_gb: 64, max_model_slots: 1 } }), pins),
    ).toMatchObject({
      exceeds: true,
      limit: 'slots',
    });
    expect(
      pinnedMemory(snapshot({ memory: { total_gb: 16, max_model_slots: 1 } }), pins),
    ).toMatchObject({
      exceeds: true,
      limit: 'memory',
    });
    expect(
      pinnedMemory(snapshot({ memory: { total_gb: 64, max_model_slots: 2 } }), pins).limit,
    ).toBeUndefined();
  });
});
