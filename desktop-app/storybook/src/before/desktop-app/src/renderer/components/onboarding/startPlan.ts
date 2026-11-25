import type { Action, Snapshot } from '../../../shared/contracts';
import { startingModel } from '../../models/selection';
import type { ContributionMode } from './ModeChoice';

// How the chosen models start: Autopilot, the plain `start` action after a runtime rejected
// Autopilot, or a local-only start that never joins the network.
export type StartMethod = 'autopilot' | 'manual' | 'local';

export const methodFor = (mode: ContributionMode, rejected: boolean): StartMethod =>
  mode === 'local' ? 'local' : rejected ? 'manual' : 'autopilot';

// Autopilot starts the pinned models, or the starting model when nothing is pinned; the other
// methods start exactly the chosen models.
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
  return { action: 'start', models, local: method === 'local', endpoint: true };
}
