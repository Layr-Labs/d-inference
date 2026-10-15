import type { Action, Snapshot } from '../../../shared/contracts';
import { startingModel } from '../../models/selection';

// How the chosen models start: Autopilot, or the plain `start` action after a runtime rejected
// Autopilot.
export type StartMethod = 'autopilot' | 'manual';

export const methodFor = (rejected: boolean): StartMethod => (rejected ? 'manual' : 'autopilot');

// Autopilot starts the pinned models, or the starting model when nothing is pinned; a manual
// start starts exactly the chosen models.
export function startModels(snapshot: Snapshot, method: StartMethod, pinned: string[]) {
  if (method !== 'autopilot' || pinned.length) return pinned;
  const model = startingModel(snapshot);
  return model ? [model.id] : [];
}

export function startAction(snapshot: Snapshot, method: StartMethod, pinned: string[]): Action {
  const models = startModels(snapshot, method, pinned);
  if (method === 'autopilot') {
    const downloads = snapshot.models
      .filter((model) => models.includes(model.id) && !model.downloaded)
      .map((model) => model.id);
    return {
      action: 'autopilot',
      models,
      pinned: [...pinned].sort(),
      ...(downloads.length ? { downloads } : {}),
      endpoint: true,
    };
  }
  return { action: 'start', models, local: false, endpoint: true };
}
