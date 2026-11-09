import type { Action, Snapshot } from '../../shared/contracts';
import type { ClusterState, ClusterStatus } from '../../shared/cluster';
import {
  previewOperation,
  previewParam,
  recordOperation,
  type FeaturePreview,
  type PreviewStore,
} from './types';

// Development preview of clusters: `darkbloom cluster status --json` for each state, and the
// pair's actions. `&cluster=` picks the state (`not_paired`, the default, `serving`, `loading`,
// `not_serving`, `stopped`, `away`, `unreadable`, `error`), `&cluster=unsupported` a runtime
// from before clusters, and `&cluster-role=member` the Mac that follows. Never used for live data.

export type PreviewPairState = Exclude<ClusterState, 'unknown'> | 'error';

const states: Record<string, PreviewPairState> = {
  not_paired: 'not_paired',
  serving: 'serving',
  loading: 'loading',
  not_serving: 'not_serving',
  stopped: 'stopped',
  away: 'other_mac_away',
  other_mac_away: 'other_mac_away',
  unreadable: 'pairing_unreadable',
  pairing_unreadable: 'pairing_unreadable',
  error: 'error',
};

export interface PreviewPair {
  state: PreviewPairState;
  role: 'leader' | 'member';
  model: { id: string; name: string };
  mode: string;
  split: string;
  serves: 'network' | 'local' | 'both';
}

export const previewModels = {
  qwen: { id: 'mlx-community/Qwen3.8-27B-4bit-mtp', name: 'Qwen 3.8 27B' },
  gemma: { id: 'mlx-community/gemma-4-26b-qat-4bit', name: 'Gemma 4 26B QAT' },
  glm: { id: 'mlx-community/GLM-5.3-Flash-4bit', name: 'GLM-5.3-Flash' },
};

const initial = (): PreviewPair => ({
  state: states[previewParam('cluster') ?? ''] ?? 'not_paired',
  role: previewParam('cluster-role') === 'member' ? 'member' : 'leader',
  model: previewModels.qwen,
  mode: 'tensor parallel',
  split: 'M3 Ultra 50% / M5 Max 50%',
  serves: 'both',
});

const pair: PreviewPair = initial();

export const unsupported = () => previewParam('cluster') === 'unsupported';

export const previewPair = (): Readonly<PreviewPair> => pair;

// Set once the pair changed outside an action (a setup's end): the snapshot follows at the next
// action, the first moment this module holds the preview's store.
let changed = false;

// The preview's pair after a setup, a leave or an action.
export function setPreviewPair(next: Partial<PreviewPair>) {
  Object.assign(pair, next);
  changed = true;
}

// Back to the pair the query names (tests).
export function resetPreviewPair() {
  Object.assign(pair, initial());
  changed = false;
}

const names = () =>
  pair.role === 'leader'
    ? { thisMac: 'Studio A', other: 'Apple M5 Max, 128 GB' }
    : { thisMac: 'Studio B', other: 'Apple M3 Ultra, 256 GB' };

const servesLine: Record<PreviewPair['serves'], string> = {
  network: 'Serves: through Darkbloom',
  local: 'Serves: locally only',
  both: 'Serves: through Darkbloom, and on its local API with you first',
};

const unpaired = {
  paired: null,
  role: null,
  other_mac: null,
  model: null,
  mode: null,
  split: null,
  serves: null,
} as const;

export function previewClusterStatus(): ClusterStatus {
  const { thisMac, other } = names();
  const leader = pair.role === 'leader';
  const cluster = leader
    ? `Cluster: this Mac (${thisMac}) leads · the other Mac (${other}) follows`
    : `Cluster: this Mac (${thisMac}) follows · the other Mac (${other}) leads`;
  const model = `Model: ${pair.model.name} · ${pair.mode} · ${pair.split}`;
  const base: ClusterStatus = {
    schema: 1,
    paired: true,
    role: pair.role,
    this_mac: thisMac,
    other_mac: { name: other, answers: true },
    model: pair.model,
    mode: pair.mode,
    split: pair.split,
    serves: pair.serves === 'local' ? 'local' : 'darkbloom',
    state: 'serving',
    reason: null,
    next: null,
    lines: [cluster, model, servesLine[pair.serves]],
    service: { running: true, starts_at_login: true },
    exit_code: 0,
  };
  switch (pair.state) {
    case 'not_paired':
      return {
        ...base,
        ...unpaired,
        paired: false,
        state: 'not_paired',
        lines: ['This Mac isn’t in a two-Mac cluster.'],
        service: null,
        exit_code: 6,
      };
    case 'serving':
      return {
        ...base,
        lines: [
          ...base.lines,
          pair.serves === 'local'
            ? `✓ Serving ${pair.model.name} on the leading Mac’s local API only (${pair.mode}).`
            : `✓ Serving ${pair.model.name} through Darkbloom on both Macs (${pair.mode}).`,
          ...(pair.serves === 'both'
            ? [
                '  Pair: Darkbloom and you, me first — open to Darkbloom (your last request 14 minutes ago)',
              ]
            : []),
          ...(pair.serves === 'network'
            ? []
            : [
                'Local API: http://127.0.0.1:8001/v1 on this Mac, and port 8001 of its LAN or tailnet address (`darkbloom local` shows the key)',
              ]),
        ],
      };
    case 'loading':
      return {
        ...base,
        state: 'loading',
        reason: 'The pair is not serving yet: checking both Macs with Apple',
        next: 'Leave both Macs running: Darkbloom checks them by itself.',
        lines: [
          ...base.lines,
          `Starting ${pair.model.name}: loaded on both Macs; checking with Darkbloom before it offers the pair.`,
        ],
        exit_code: 3,
      };
    case 'not_serving':
      return {
        ...base,
        state: 'not_serving',
        reason:
          'This Mac can’t reach the other Mac over the cable: macOS keeps Darkbloom off the local network',
        next: 'On this Mac: System Settings → Privacy & Security → Local Network → turn on “Darkbloom”; if it isn’t listed, click Allow when macOS asks on this Mac’s screen, the next time Darkbloom dials over the cable (on a Mac with no display, through Screen Sharing); then run `darkbloom start` here, or choose Retry in `darkbloom cluster` on the other Mac.',
        lines: [
          ...base.lines,
          'Not serving: This Mac can’t reach the other Mac over the cable: macOS keeps Darkbloom off the local network.',
        ],
        exit_code: 3,
      };
    case 'stopped':
      return {
        ...base,
        state: 'stopped',
        next: '`darkbloom start` starts the pair again. If the other Mac left the pair, `darkbloom cluster leave` here unpairs this Mac too.',
        lines: [...base.lines, `Stopped; last model ${pair.model.name}`],
        exit_code: 4,
      };
    case 'other_mac_away':
      return {
        ...base,
        other_mac: { name: other, answers: false },
        state: 'other_mac_away',
        reason: `The other Mac (${other}) isn’t answering over the cable`,
        next: 'On that Mac, run `darkbloom start` or `darkbloom cluster`. Or serve this Mac alone: `darkbloom start --solo`. If the other Mac left the pair, `darkbloom cluster leave` here unpairs this Mac too.',
        lines: [...base.lines, `The other Mac (${other}) isn’t answering over the cable.`],
        exit_code: 5,
      };
    case 'pairing_unreadable': {
      const reason =
        'This Mac’s pairing record couldn’t be read (pairings.json is malformed; nothing is trusted from it), so it may be in a two-Mac cluster.';
      return {
        ...base,
        ...unpaired,
        state: 'pairing_unreadable',
        reason,
        next: 'Run `darkbloom cluster` on this Mac to check it.',
        lines: [reason],
        service: { running: false, starts_at_login: false },
        exit_code: 7,
      };
    }
    case 'error':
      return {
        ...base,
        ...unpaired,
        state: 'unknown',
        lines: [],
        service: null,
        exit_code: 1,
        error: 'The cluster status didn’t answer in 25 s.',
      };
  }
}

// `Snapshot.pair` as the runtime derives it from this Mac's own files.
function snapshotPair(): Snapshot['pair'] {
  if (pair.state === 'not_paired') return null;
  if (pair.state === 'pairing_unreadable') return { model: null, state: 'unreadable', leads: null };
  const leads = pair.role === 'leader';
  const state =
    pair.state === 'stopped'
      ? 'stopped'
      : pair.state === 'other_mac_away'
        ? 'not_running'
        : pair.state === 'serving' && leads
          ? 'serving'
          : 'started';
  return { model: pair.model.name, state, leads };
}

// An older runtime lists no capabilities, which the app reads as "everything it knew then": the
// list starts from those, so adding the cluster's changes nothing else in the preview.
const olderRuntime = ['autopilot', 'waitlist', 'request-history'];
// Whether this preview's runtime offers Autopilot while it isn't paired (from the first snapshot).
let autopilot: boolean | undefined;

function withPair(snapshot: Snapshot): Snapshot {
  const current = snapshot.capabilities ?? olderRuntime;
  autopilot ??= current.includes('autopilot');
  const paired = !unsupported() && pair.state !== 'not_paired';
  // The list as it is, in its order: a paired Mac's runtime offers no Autopilot, which serves
  // one Mac, and gets it back where it was once the Mac leaves the pair.
  const listed = current.filter(
    (capability) =>
      capability !== 'cluster' &&
      capability !== 'cluster_session' &&
      !(paired && capability === 'autopilot'),
  );
  const capabilities =
    autopilot && !paired && !listed.includes('autopilot') ? ['autopilot', ...listed] : listed;
  if (unsupported()) return { ...snapshot, capabilities };
  return {
    ...snapshot,
    capabilities: [...capabilities, 'cluster', 'cluster_session'],
    pair: snapshotPair(),
  };
}

const settle = (ms = 900) => new Promise((resolve) => setTimeout(resolve, ms));

// The page reads the status again when the snapshot's resource revision moves, as on the native
// 30-second clock.
let revision = 0;
function publish(store: PreviewStore, patch: Partial<Snapshot> = {}) {
  changed = false;
  revision += 1;
  store.set({ ...withPair(store.get()), ...patch, resource_revision: `cluster-${revision}` });
}

// The preview's snapshot follows the pair at once, as when a guided setup ends.
export const publishPair = (store: PreviewStore) => publish(store);

// A start or restart loads for a while, then serves.
function load(store: PreviewStore) {
  setPreviewPair({ state: 'loading' });
  publish(store);
  setTimeout(() => {
    if (pair.state !== 'loading') return;
    setPreviewPair({ state: 'serving' });
    publish(store);
  }, 4000);
}

async function pairAction(store: PreviewStore, action: Action) {
  const paired = pair.state !== 'not_paired' && pair.state !== 'error';
  const readable = paired && pair.state !== 'pairing_unreadable';
  if (action.action === 'cluster_leave' && readable) {
    await settle();
    setPreviewPair({ state: 'not_paired' });
    publish(store);
    return recordOperation(store, previewOperation(action));
  }
  if (action.action === 'start' && action.solo && paired) {
    await settle();
    if (readable) setPreviewPair({ state: 'stopped' });
    publish(store, { state: 'running', readiness: 'Connected and ready for requests' });
    return recordOperation(store, previewOperation(action));
  }
  if (!readable) return undefined;
  if (action.action === 'start' && action.models.length === 0) {
    await settle();
    load(store);
    publish(store, { state: 'running', readiness: 'Connected and ready for requests' });
    return recordOperation(store, previewOperation(action));
  }
  if (action.action === 'restart') {
    await settle();
    load(store);
    return recordOperation(store, previewOperation(action));
  }
  if (action.action === 'stop') {
    await settle();
    setPreviewPair({ state: 'stopped' });
    publish(store, { state: 'stopped', readiness: 'Provider stopped' });
    return recordOperation(store, previewOperation(action));
  }
  return undefined;
}

export const clusterPreview: FeaturePreview = {
  // The Mac that follows asks the leading Mac over the cable, so its status takes a moment.
  resources: () =>
    unsupported()
      ? {}
      : {
          cluster: new Promise<ClusterStatus>((resolve) =>
            setTimeout(() => resolve(previewClusterStatus()), pair.role === 'member' ? 1600 : 250),
          ),
        },
  async act(store, action) {
    if (changed) publish(store);
    return pairAction(store, action);
  },
  snapshot: withPair,
};
