import type { Action, Snapshot } from '../../../shared/contracts';
import { servesNetwork, startingModel } from '../../models/selection';

// How the chosen models start: Autopilot, or the plain `start` action after a runtime rejected
// Autopilot.
export type StartMethod = 'autopilot' | 'manual';

export const methodFor = (rejected: boolean): StartMethod => (rejected ? 'manual' : 'autopilot');

// Onboarding always serves the network. Pins can include models found only on disk; the network
// can't route to those and Autopilot refuses to start with them, so they're dropped.
export function usablePins(snapshot: Snapshot, pinned: string[]) {
  return pinned.filter((id) =>
    snapshot.models.some((model) => model.id === id && servesNetwork(model)),
  );
}

// Autopilot starts the pinned models, or the starting model when nothing is pinned; a manual
// start starts exactly the chosen models.
export function startModels(snapshot: Snapshot, method: StartMethod, pinned: string[]) {
  const pins = usablePins(snapshot, pinned);
  if (method !== 'autopilot' || pins.length) return pins;
  const model = startingModel(snapshot);
  return model ? [model.id] : [];
}

type Pair = NonNullable<Snapshot['pair']>;

// How onboarding names the pair's model: its name, or "its model" before the pair has one.
export const pairModel = (pair: Pair) => pair.model ?? 'its model';

// Whether Start serving can start the pair. A pair with no model yet, or whose pairing record can't
// be read, needs Terminal first, so the page offers no Start there and says why: the runtime
// refused that Start (#1905's review).
export const pairStartable = (pair: Pair) => pair.model !== null && pair.state !== 'unreadable';

// Why the page offers no Start serving on this pair (`pairStartable`), under the button.
export const pairBlocked = (pair: Pair) =>
  pair.state === 'unreadable'
    ? 'Check the pairing in Terminal first.'
    : 'Choose the pair’s model in Terminal first.';

// Where the pair's model is chosen: on the Mac that leads it.
const leadingMac = (pair: Pair) =>
  pair.leads === true
    ? 'on this Mac'
    : pair.leads === false
      ? 'on the other Mac, which leads the pair'
      : 'on the leading Mac';

// The pair as it is, from the runtime's own view, then what Start serving does there: "serves" only
// when the runtime says it serves (#1905's review). An older runtime says no state: its words are
// true in every state.
export function pairLead(pair: Pair): string {
  if (pair.state === 'unreadable')
    return 'This Mac’s pairing record couldn’t be read, so it may be in a pair. Run “darkbloom cluster” in Terminal on this Mac to check it.';
  if (pair.model === null)
    return `This Mac is in a pair that has no model yet. Choose one with “darkbloom cluster” in Terminal ${leadingMac(pair)}, then come back to Start serving.`;
  const model = pair.model;
  switch (pair.state) {
    case 'serving':
      return `This Mac serves in a pair with ${model}. Start serving keeps it serving.`;
    case 'started':
      return `This Mac is in a pair, started with ${model}. Start serving makes sure it serves.`;
    case 'not_running':
      return `This Mac is in a pair that isn’t running here. Start serving starts it with ${model}.`;
    case 'stopped':
      return `This Mac is in a pair, which is stopped. Start serving starts it with ${model}.`;
    default:
      return `This Mac is in a pair. Start serving starts the pair with ${model}.`;
  }
}

// On a paired Mac a start starts the pair, never this Mac alone, and the pair serves its own model
// and its own local API, so the action names neither.
export function startAction(snapshot: Snapshot, method: StartMethod, pinned: string[]): Action {
  if (snapshot.pair) return { action: 'start', models: [], local: false };
  const models = startModels(snapshot, method, pinned);
  if (method === 'autopilot') {
    const downloads = snapshot.models
      .filter((model) => models.includes(model.id) && !model.downloaded)
      .map((model) => model.id);
    return {
      action: 'autopilot',
      models,
      pinned: usablePins(snapshot, pinned).sort(),
      ...(downloads.length ? { downloads } : {}),
      endpoint: true,
    };
  }
  return { action: 'start', models, local: false, endpoint: true };
}
