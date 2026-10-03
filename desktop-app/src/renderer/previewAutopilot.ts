import type { AutopilotAction, AutopilotStatus } from '../shared/autopilot';
import type { Action, NativeModel, Operation, Snapshot } from '../shared/contracts';
import { onboardingScenario } from './previewEligibility';

// Development preview only. The preview Mac runs Autopilot with a small pool unless
// `?preview&autopilot=` asks for `shadow` (learning, nothing changes), `off` (manual selection)
// or `unsupported` (a runtime without Autopilot, which rejects every Autopilot action).
const mode = new URLSearchParams(globalThis.location?.search).get('autopilot') ?? 'on';
const settleMs = 600;
const downloadTickMs = 250;
// Autopilot reconsiders what's loaded on each tick.
export const autopilotTickMs = 8000;

interface Store {
  get: () => Snapshot;
  set: (snapshot: Snapshot) => void;
}

const catalogAdditions: NativeModel[] = [
  {
    id: 'devstral-2-24b',
    display_name: 'Devstral 2 24B',
    size_gb: 14.3,
    downloaded: false,
    serving: false,
    loaded: false,
    eligible: true,
    description: 'Agentic coding across large repositories.',
    family: 'Mistral',
    quantization: '4-bit',
  },
  {
    id: 'llama-4-scout',
    display_name: 'Llama 4 Scout',
    size_gb: 32.4,
    downloaded: false,
    serving: false,
    loaded: false,
    eligible: true,
    description: 'Long-context mixture-of-experts generalist.',
    family: 'Meta',
    quantization: '4-bit',
  },
  {
    id: 'kimi-k2.6',
    display_name: 'Kimi K2.6',
    size_gb: 380,
    downloaded: false,
    serving: false,
    loaded: false,
    eligible: false,
    reason: 'Needs 512 GB of unified memory.',
    description: 'Frontier-scale reasoning and tool use.',
    family: 'Moonshot',
    quantization: '4-bit',
  },
];

const livePhase = (): AutopilotStatus['phase'] => (mode === 'shadow' ? 'shadow' : 'active');

export function withPreviewAutopilot(snapshot: Snapshot): Snapshot {
  if (mode === 'unsupported') return snapshot;
  const off: AutopilotStatus = {
    enabled: false,
    paused: false,
    selected: [],
    pinned: [],
    phase: 'off',
  };
  if (onboardingScenario) return { ...snapshot, autopilot: off };
  const models = [
    ...snapshot.models.map((model) =>
      model.id === 'qwen-3.5-9b' ? { ...model, downloaded: true, memory_gb: 7.2 } : model,
    ),
    ...catalogAdditions,
  ];
  const pool = models.filter((model) => model.downloaded).map((model) => model.id);
  return {
    ...snapshot,
    models,
    autopilot:
      mode === 'off'
        ? { ...off, selected: pool, pinned: ['gemma-4-26b'] }
        : { ...off, enabled: true, selected: pool, pinned: ['gemma-4-26b'], phase: livePhase() },
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, settleMs));
const downloadedPool = (models: NativeModel[]) =>
  models.filter((model) => model.downloaded && model.eligible).map((model) => model.id);

function operation(action: Action, state: Operation['state'], extra: Partial<Operation> = {}) {
  return {
    id: crypto.randomUUID(),
    action: action.action,
    state,
    started_at: Date.now() / 1000,
    message: 'Preview action complete',
    cancellable: false,
    ...extra,
  };
}

function record(store: Store, done: Operation, next: Partial<Snapshot>) {
  const current = store.get();
  store.set({ ...current, ...next, operations: [done, ...current.operations].slice(0, 10) });
  return done;
}

function enable(snapshot: Snapshot, action: AutopilotAction): Partial<Snapshot> {
  const models = snapshot.models.map((model) =>
    action.models.includes(model.id)
      ? { ...model, downloaded: true, serving: true, loaded: true }
      : model,
  );
  return {
    state: 'running',
    readiness: 'Connected and ready for requests',
    models,
    autopilot: {
      enabled: true,
      paused: false,
      selected: downloadedPool(models),
      pinned: action.pinned,
      phase: livePhase(),
    },
  };
}

// The download runs for a few seconds, reporting its model and progress.
function download(store: Store, action: Action, id: string) {
  const running = operation(action, 'running', {
    model: id,
    progress: 0,
    message: 'Downloading…',
  });
  record(store, running, {});
  const timer = setInterval(() => {
    const current = store.get();
    const previous = current.operations.find((item) => item.id === running.id);
    const progress = Math.min(1, (previous?.progress ?? 0) + 0.1);
    const done = progress >= 1;
    store.set({
      ...current,
      models: done
        ? current.models.map((model) =>
            model.id === id
              ? { ...model, downloaded: true, memory_gb: +(model.size_gb * 1.3).toFixed(1) }
              : model,
          )
        : current.models,
      operations: current.operations.map((item) =>
        item.id === running.id
          ? {
              ...item,
              progress,
              state: done ? 'succeeded' : 'running',
              message: done ? 'Download complete' : 'Downloading…',
            }
          : item,
      ),
    });
    if (done) clearInterval(timer);
  }, downloadTickMs);
  return running;
}

function policy(snapshot: Snapshot, action: Action): Partial<Snapshot> {
  const status = snapshot.autopilot!;
  switch (action.action) {
    case 'autopilot_pin':
      if (!action.models.every((id) => status.selected.includes(id)))
        throw new Error('Pins must be selected Autopilot models.');
      return {
        autopilot: { ...status, pinned: [...new Set([...status.pinned, ...action.models])] },
      };
    case 'autopilot_unpin':
      return {
        autopilot: { ...status, pinned: status.pinned.filter((id) => !action.models.includes(id)) },
      };
    case 'autopilot_pause':
      return { autopilot: { ...status, paused: true, phase: 'paused' } };
    case 'autopilot_resume':
      return { autopilot: { ...status, paused: false, phase: livePhase() } };
    case 'autopilot_disable':
      return { autopilot: { ...status, enabled: false, paused: false, phase: 'off' } };
    case 'autopilot_models':
      return { autopilot: { ...status, selected: downloadedPool(snapshot.models) } };
    default:
      return {};
  }
}

function remove(snapshot: Snapshot, id: string): Partial<Snapshot> {
  const status = snapshot.autopilot;
  if (status?.enabled && status.pinned.includes(id)) throw new Error('Unpin this model first.');
  return {
    models: snapshot.models.map((model) =>
      model.id === id
        ? { ...model, downloaded: false, loaded: false, serving: false, memory_gb: undefined }
        : model,
    ),
    autopilot: status && { ...status, selected: status.selected.filter((item) => item !== id) },
  };
}

// Handles the actions whose preview outcome depends on Autopilot; anything else returns
// undefined and falls through to the generic preview.
export async function previewModelAction(
  store: Store,
  action: Action,
): Promise<Operation | undefined> {
  const autopilotAction = action.action.startsWith('autopilot');
  if (autopilotAction && mode === 'unsupported') {
    await settle();
    throw new Error('Unknown action');
  }
  if (action.action === 'download') return download(store, action, action.model);
  if (action.action === 'remove') {
    const next = remove(store.get(), action.model);
    return record(store, operation(action, 'succeeded'), next);
  }
  if (!autopilotAction) return undefined;
  await settle();
  const next =
    action.action === 'autopilot' ? enable(store.get(), action) : policy(store.get(), action);
  return record(store, operation(action, 'succeeded'), next);
}

const memoryOf = (model: NativeModel) => model.memory_gb ?? model.size_gb * 1.3;

// One Autopilot decision. Demand moves between the unpinned pool models one turn at a time;
// Autopilot keeps every pinned pool model loaded plus the one in demand, within the memory cap.
export function autopilotStep(snapshot: Snapshot, turn: number): Snapshot {
  const status = snapshot.autopilot;
  if (!status?.enabled || status.paused || status.phase !== 'active') return snapshot;
  if (snapshot.state !== 'running') return snapshot;
  const pool = snapshot.models.filter(
    (model) => model.downloaded && status.selected.includes(model.id),
  );
  const pinned = pool.filter((model) => status.pinned.includes(model.id));
  const rotating = pool.filter((model) => !status.pinned.includes(model.id));
  const demanded = rotating.length ? rotating[turn % rotating.length] : undefined;
  let free = snapshot.memory.total_gb * 0.9;
  const loaded = new Set<string>();
  for (const model of demanded ? [...pinned, demanded] : pinned)
    if (memoryOf(model) <= free) {
      loaded.add(model.id);
      free -= memoryOf(model);
    }
  const models = snapshot.models.map((model) =>
    status.selected.includes(model.id)
      ? { ...model, loaded: loaded.has(model.id), serving: loaded.has(model.id) }
      : model,
  );
  return { ...snapshot, models, machine: { ...snapshot.machine, models: [...loaded] } };
}

let subscribers = 0;
let timer: ReturnType<typeof setInterval> | undefined;

// Runs while anything watches the preview state.
export function simulateAutopilot(store: Store) {
  subscribers += 1;
  if (!timer) {
    let turn = 0;
    timer = setInterval(() => {
      turn += 1;
      const current = store.get();
      const next = autopilotStep(current, turn);
      if (next !== current) store.set(next);
    }, autopilotTickMs);
  }
  return () => {
    subscribers -= 1;
    if (subscribers || !timer) return;
    clearInterval(timer);
    timer = undefined;
  };
}
