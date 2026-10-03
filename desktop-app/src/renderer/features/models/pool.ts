import type { AutopilotStatus } from '../../../shared/autopilot';
import type { NativeModel, Operation, Snapshot } from '../../../shared/contracts';

// A runtime without the Autopilot block can't run it, so it only ever gets manual selection.
export type ModelsMode = 'autopilot' | 'manual' | 'unsupported';
export const modelsMode = ({ autopilot }: Snapshot): ModelsMode =>
  !autopilot ? 'unsupported' : autopilot.enabled ? 'autopilot' : 'manual';

// `outside` is downloaded but not yet in the pool: downloading alone never adds to it.
export type PoolState =
  'ineligible' | 'downloading' | 'available' | 'outside' | 'pool' | 'loaded' | 'pinned';

export const poolLabels: Record<PoolState, string> = {
  ineligible: 'Not available',
  downloading: 'Downloading',
  available: 'Not downloaded',
  outside: 'On this Mac · not in pool',
  pool: 'In pool',
  loaded: 'Loaded now · Autopilot',
  pinned: 'Pinned · always on',
};

// `requested` maps operations this page started to their model, for runtimes that don't
// attribute a download themselves.
export function runningDownload(
  snapshot: Snapshot,
  model: string,
  requested: Record<string, string>,
): Operation | undefined {
  return snapshot.operations.find(
    (operation) =>
      operation.action === 'download' &&
      operation.state === 'running' &&
      (operation.model ?? requested[operation.id]) === model,
  );
}

export function poolState(
  model: NativeModel,
  status: AutopilotStatus,
  downloading: boolean,
): PoolState {
  if (!model.eligible) return 'ineligible';
  if (downloading) return 'downloading';
  if (!model.downloaded) return 'available';
  if (!status.selected.includes(model.id)) return 'outside';
  if (status.pinned.includes(model.id)) return 'pinned';
  return model.loaded ? 'loaded' : 'pool';
}

export const poolFilters = [
  { id: 'all', label: 'All', states: [] },
  { id: 'pool', label: 'In pool', states: ['pool', 'loaded', 'pinned'] },
  { id: 'pinned', label: 'Pinned', states: ['pinned'] },
  { id: 'available', label: 'Not downloaded', states: ['available', 'downloading'] },
] as const satisfies readonly { id: string; label: string; states: readonly PoolState[] }[];
export type PoolFilter = (typeof poolFilters)[number]['id'];

export function inFilter(state: PoolState, filter: PoolFilter) {
  const states: readonly PoolState[] = poolFilters.find((item) => item.id === filter)!.states;
  return !states.length || states.includes(state);
}

export interface PhaseCopy {
  label: string;
  tone: 'online' | 'warning' | 'idle';
  detail?: string;
  refresh?: boolean;
}

// Only `active` (and its transitions) changes what's loaded; every other phase leaves models
// as they are, and the copy says so.
export function phaseCopy(status: AutopilotStatus, running: boolean): PhaseCopy {
  if (status.paused || status.phase === 'paused')
    return {
      label: 'Paused',
      tone: 'warning',
      detail:
        'Loaded models stay as they are and pins still protect theirs. Resume to let Autopilot change what’s loaded again.',
    };
  switch (status.phase) {
    case 'active':
      return { label: 'On', tone: 'online' };
    case 'transitioning':
      return {
        label: 'Changing models',
        tone: 'online',
        detail: 'Autopilot is swapping what’s loaded. Requests in progress finish first.',
      };
    case 'recovering':
      return {
        label: 'Recovering',
        tone: 'warning',
        detail: 'Autopilot is reconciling what’s loaded after an interruption.',
      };
    case 'shadow':
      return {
        label: 'Learning',
        tone: 'idle',
        detail:
          'Autopilot is learning; models stay as they are for now. It records what it would load as demand changes, but doesn’t change what’s in memory yet.',
      };
    case 'waiting':
      return {
        label: 'Waiting',
        tone: 'idle',
        detail:
          'Autopilot is waiting for the network to hand it control. Models stay as they are until then.',
      };
    case 'waiting_inventory':
      return {
        label: 'Waiting for the pool',
        tone: 'warning',
        detail:
          'Models on this Mac changed. Refresh the pool so Autopilot can use them; models stay as they are until then.',
        refresh: true,
      };
    default:
      return running
        ? {
            label: 'Starting',
            tone: 'idle',
            detail: 'The runtime hasn’t reported Autopilot’s state yet. Models stay as they are.',
          }
        : {
            label: 'Ready',
            tone: 'idle',
            detail: 'Autopilot takes over once this Mac is serving.',
          };
  }
}
