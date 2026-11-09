import { describe, expect, it } from 'vitest';
import {
  methodFor,
  pairLead,
  pairModel,
  pairStartable,
  startAction,
} from '../src/renderer/components/onboarding/startPlan';
import { pinnedMemory, startingModel } from '../src/renderer/models/selection';
import { models, pairedMac, snapshot } from './onboardingFixtures';

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

describe('a paired Mac', () => {
  it('starts the pair with its own model: no model and no local API of its own', () => {
    expect(startAction(pairedMac(), 'manual', ['gpt-oss-20b'])).toEqual({
      action: 'start',
      models: [],
      local: false,
    });
  });

  it('names the pair’s model, or “its model” before the pair has one', () => {
    expect(pairModel({ model: 'Qwen 3.8 27B' })).toBe('Qwen 3.8 27B');
    expect(pairModel({ model: null })).toBe('its model');
  });

  // #1905's review: the page said “This Mac serves in a pair” whatever the pair's state.
  it('says the pair as it is, and what Start serving does there', () => {
    const pair = pairedMac().pair!;
    expect(pairLead({ ...pair, state: 'serving' })).toBe(
      'This Mac serves in a pair with Qwen 3.8 27B. Start serving keeps it serving.',
    );
    expect(pairLead({ ...pair, state: 'started', leads: false })).toBe(
      'This Mac is in a pair, started with Qwen 3.8 27B. Start serving makes sure it serves.',
    );
    expect(pairLead({ ...pair, state: 'not_running' })).toBe(
      'This Mac is in a pair that isn’t running here. Start serving starts it with Qwen 3.8 27B.',
    );
    expect(pairLead(pair)).toBe(
      'This Mac is in a pair, which is stopped. Start serving starts it with Qwen 3.8 27B.',
    );
    // A runtime from before the state was reported: words that are true in every state.
    expect(pairLead({ model: 'Qwen 3.8 27B' })).toBe(
      'This Mac is in a pair. Start serving starts the pair with Qwen 3.8 27B.',
    );
  });

  // #1905's review: a pair with no model yet was offered Start serving, which the runtime then
  // refused. Its model is chosen in Terminal, on the Mac that leads the pair.
  it('says what works first where Start serving can’t start the pair', () => {
    const pair = pairedMac().pair!;
    expect(pairLead({ ...pair, model: null })).toBe(
      'This Mac is in a pair that has no model yet. Choose one with “darkbloom cluster” in Terminal on this Mac, then come back to Start serving.',
    );
    expect(pairLead({ ...pair, model: null, leads: false })).toBe(
      'This Mac is in a pair that has no model yet. Choose one with “darkbloom cluster” in Terminal on the other Mac, which leads the pair, then come back to Start serving.',
    );
    expect(pairLead({ model: null })).toBe(
      'This Mac is in a pair that has no model yet. Choose one with “darkbloom cluster” in Terminal on the leading Mac, then come back to Start serving.',
    );
    expect(pairLead({ model: null, state: 'unreadable', leads: null })).toBe(
      'This Mac’s pairing record couldn’t be read, so it may be in a pair. Run “darkbloom cluster” in Terminal on this Mac to check it.',
    );
    expect(pairStartable(pair)).toBe(true);
    expect(pairStartable({ model: 'Qwen 3.8 27B' })).toBe(true);
    expect(pairStartable({ ...pair, model: null })).toBe(false);
    expect(pairStartable({ model: null, state: 'unreadable', leads: null })).toBe(false);
  });
});
