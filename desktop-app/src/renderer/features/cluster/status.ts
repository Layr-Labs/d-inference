import type { ClusterState, ClusterStatus } from '../../../shared/cluster';

// The pair as `darkbloom cluster status --json` reports it, in the page's words. Every reason and
// next step stays the runtime's own sentence; only the state's name and how the pair serves are
// the app's labels for the CLI's values.

export type Tone = 'ready' | 'pending' | 'failed' | 'idle';

export const stateWords: Record<ClusterState, string> = {
  serving: 'Serving',
  loading: 'Loading',
  not_serving: 'Not serving',
  stopped: 'Stopped',
  other_mac_away: 'Other Mac away',
  not_paired: 'Not paired',
  unknown: 'Unknown',
  pairing_unreadable: 'Pairing unreadable',
};

export const stateTone: Record<ClusterState, Tone> = {
  serving: 'ready',
  loading: 'pending',
  not_serving: 'failed',
  stopped: 'idle',
  other_mac_away: 'pending',
  not_paired: 'idle',
  unknown: 'idle',
  pairing_unreadable: 'failed',
};

// Whether the status is one of the states this app knows; a newer runtime may add one.
export const knownState = (state: unknown): state is ClusterState =>
  typeof state === 'string' && state in stateWords;

export type ServingWay = 'network' | 'local' | 'both';

export const servingWords: Record<ServingWay, string> = {
  network: 'Darkbloom network',
  local: 'Only me',
  both: 'Both, me first',
};

// `serves` says Darkbloom or local; Both, me first is Darkbloom with the local API beside it,
// which the status's own `Serves:` line says.
export function servingWay(status: ClusterStatus): ServingWay | null {
  if (status.serves === 'local') return 'local';
  if (status.serves !== 'darkbloom') return null;
  const line = status.lines.find((item) => /^\s*Serves:/.test(item));
  return line && /local API/.test(line) ? 'both' : 'network';
}

// "Serves: through Darkbloom (not offered)": set to serve through Darkbloom, which doesn't have
// the pair.
export const notOffered = (status: ClusterStatus) =>
  status.lines.some((item) => /^\s*Serves:.*\(not offered\)/.test(item));

export interface Share {
  name: string;
  amount: string;
  weight: number;
}

// "M3 Ultra 40 layers / M5 Ultra 24 layers" or "M3 Ultra 50% / M5 Max 50%": each Mac's share,
// weighted for a bar. Null when it reads otherwise.
export function shares(split: string | null): Share[] | null {
  if (!split) return null;
  const parts = split.split(' / ').map((part) => part.trim());
  if (parts.length < 2) return null;
  const read = parts.map((part) => part.match(/^(.+?)\s+(\d+(?:\.\d+)?)(\s?%| layers?)$/));
  if (read.some((match) => !match)) return null;
  const amounts = read.map((match) => Number(match![2]));
  const total = amounts.reduce((sum, amount) => sum + amount, 0);
  if (!(total > 0)) return null;
  return read.map((match, index) => ({
    name: match![1],
    amount: `${match![2]}${match![3].trim() === '%' ? '%' : match![3]}`,
    weight: amounts[index] / total,
  }));
}

export const modelName = (status: ClusterStatus) =>
  status.model ? status.model.name || status.model.id : null;

// What the page offers in each state. Start, Stop and Restart serving act on the pair from
// either Mac; `darkbloom restart` starts nothing that was stopped, and a pairing record that
// can't be read takes none of them.
export function pairActions(status: ClusterStatus) {
  const state = status.state;
  const readable = state !== 'pairing_unreadable';
  return {
    start: state === 'stopped' || state === 'unknown',
    stop: ['serving', 'loading', 'not_serving', 'other_mac_away', 'unknown'].includes(state),
    restart: state === 'serving' || state === 'not_serving',
    // The Mac that leads chooses the model; an unknown role is asked by the setup itself, which
    // also checks a pairing record that can't be read.
    change: status.role !== 'member',
    alone: true,
    leave: readable,
  };
}
