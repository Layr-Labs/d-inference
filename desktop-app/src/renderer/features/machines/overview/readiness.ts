import type {
  Action,
  DesktopStatus,
  NativeModel,
  Operation,
  Route,
  Snapshot,
} from '../../../../shared/contracts';
import { modelName } from '../../../models/facts';

export type ReadinessTone = 'ready' | 'pending' | 'blocked';
export type StepAction =
  | { kind: 'route'; route: Route; label: string }
  | { kind: 'act'; action: Action; label: string }
  | { kind: 'install'; label: string }
  | { kind: 'link-page'; label: string };
export interface ReadinessStep {
  id: string;
  title: string;
  detail: string;
  actions: StepAction[];
}
export interface Readiness {
  tone: ReadinessTone;
  summary: string;
  steps: ReadinessStep[];
}
export interface ReadinessFacts {
  status: DesktopStatus;
  state: Snapshot;
  update: { required: boolean; available: boolean };
}

const lifecycle: Action['action'][] = ['start', 'switch', 'stop', 'restart', 'update'];
const chooseModels: StepAction = { kind: 'route', route: 'models', label: 'Choose models' };
const restart: StepAction = {
  kind: 'act',
  action: { action: 'restart' },
  label: 'Restart provider',
};

function modelList(names: string[]) {
  return names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.at(-1)}` : names[0] || '';
}
const displayNames = (models: NativeModel[]) =>
  modelList(models.map((model) => model.display_name));
const isAre = (count: number) => (count === 1 ? 'is' : 'are');

function runtimeStep(status: DesktopStatus): ReadinessStep {
  if (status.state === 'connecting' || status.state === 'installing')
    return {
      id: 'runtime',
      title:
        status.state === 'installing' ? 'Installing the runtime' : 'Reconnecting to the runtime',
      detail:
        status.state === 'installing'
          ? 'This can take a few minutes.'
          : 'The app reconnects automatically.',
      actions: [],
    };
  const missing = status.state === 'missing';
  return {
    id: 'runtime',
    title: missing ? 'Install the Darkbloom runtime' : 'Repair the Darkbloom runtime',
    detail: status.message || 'The app can’t reach the runtime on this Mac.',
    actions: [{ kind: 'install', label: missing ? 'Install runtime' : 'Repair runtime' }],
  };
}

const operationStep = (operation: Operation): ReadinessStep => ({
  id: 'operation',
  title: `${operation.action.charAt(0).toUpperCase()}${operation.action.slice(1)} in progress`,
  detail: 'Wait for it to finish.',
  actions: [],
});

function updateStep(available: boolean): ReadinessStep {
  return {
    id: 'update',
    title: 'Update Darkbloom',
    detail: available
      ? 'This version can no longer receive network requests.'
      : 'This version can no longer receive network requests, and a compatible update isn’t available yet.',
    actions: available ? [{ kind: 'act', action: { action: 'update' }, label: 'Update now' }] : [],
  };
}

function startStep(startable: NativeModel[]): ReadinessStep {
  return startable.length
    ? {
        id: 'start',
        title: 'Start providing',
        detail: `${displayNames(startable)} ${isAre(startable.length)} selected and ready to serve.`,
        actions: [
          {
            kind: 'act',
            action: { action: 'start', models: startable.map((model) => model.id) },
            label: 'Start providing',
          },
          chooseModels,
        ],
      }
    : {
        id: 'choose',
        title: 'Choose models to serve',
        detail: 'Select at least one downloaded model, then start providing.',
        actions: [chooseModels],
      };
}

function linkStep(state: Snapshot): ReadinessStep {
  return state.link
    ? {
        id: 'link',
        title: 'Finish linking this Mac',
        detail: `Enter code ${state.link.code} in your browser to attribute this Mac’s earnings to your account.`,
        actions: [{ kind: 'link-page', label: 'Open link page' }],
      }
    : {
        id: 'link',
        title: 'Link this Mac',
        detail: 'Linking attributes this Mac’s earnings to your account.',
        actions: [{ kind: 'act', action: { action: 'link' }, label: 'Link account' }],
      };
}

// The single most relevant provider fact that keeps This Mac from serving.
function providerStep(state: Snapshot): [ReadinessStep, 'block' | 'wait'] | undefined {
  const downloaded = state.models.filter((model) => model.downloaded);
  const chosen = state.models.filter((model) => model.serving);
  const crashed = (state.activity.models || [])
    .filter((slot) => slot.state === 'crashed')
    .map((slot) => modelName(state.models, slot.model));
  if (state.state === 'draining')
    return [
      {
        id: 'draining',
        title: 'Finishing current requests',
        detail: 'The provider takes no new requests while it drains.',
        actions: [],
      },
      'wait',
    ];
  if (state.state === 'starting')
    return [
      {
        id: 'starting',
        title: 'Starting the provider',
        detail: 'Requests are served once it connects.',
        actions: [],
      },
      'wait',
    ];
  if (state.state === 'stale')
    return [
      {
        id: 'stale',
        title: 'Restart the provider',
        detail: 'The provider is running but its status is out of date. Restart it if this lasts.',
        actions: [restart],
      },
      'block',
    ];
  if (!downloaded.length)
    return [
      {
        id: 'download',
        title: 'Download a model',
        detail: 'This Mac has no models on disk yet.',
        actions: [{ kind: 'route', route: 'models', label: 'Browse models' }],
      },
      'block',
    ];
  if (state.state === 'stopped')
    return [startStep(chosen.filter((model) => model.downloaded && model.eligible)), 'block'];
  if (!chosen.length)
    return [
      {
        id: 'choose',
        title: 'Choose models to serve',
        detail: 'Select at least one downloaded model.',
        actions: [chooseModels],
      },
      'block',
    ];
  if (crashed.length)
    return [
      {
        id: 'crashed',
        title: 'Restart the provider',
        detail: `${modelList(crashed)} stopped unexpectedly.`,
        actions: [restart],
      },
      'block',
    ];
  if (!chosen.some((model) => model.loaded))
    return [
      {
        id: 'loading',
        title: 'Loading models',
        detail: `${displayNames(chosen)} ${isAre(chosen.length)} loading into memory. Requests are served once loading finishes.`,
        actions: [],
      },
      'wait',
    ];
}

// Next steps from reported facts only; admission and routing policy stay with
// the runtime and coordinator. Linking is advice: it never changes the tone.
export function assessReadiness({ status, state, update }: ReadinessFacts): Readiness {
  if (status.state !== 'ready') {
    const step = runtimeStep(status);
    return {
      tone: step.actions.length ? 'blocked' : 'pending',
      summary: 'Status unknown while disconnected',
      steps: [step],
    };
  }
  const operation = state.operations.find((item) => item.state === 'running');
  const transitioning = !!operation && lifecycle.includes(operation.action);
  const steps: ReadinessStep[] = update.required ? [updateStep(update.available)] : [];
  const provider = transitioning ? undefined : providerStep(state);
  if (provider) steps.push(provider[0]);
  const tone: ReadinessTone =
    update.required || provider?.[1] === 'block'
      ? 'blocked'
      : provider || transitioning
        ? 'pending'
        : 'ready';
  if (operation && tone !== 'ready') steps.unshift(operationStep(operation));
  if (!state.linked) steps.push(linkStep(state));
  const loaded = state.models.filter((model) => model.serving && model.loaded);
  return {
    tone,
    summary:
      tone === 'ready'
        ? `Serving ${displayNames(loaded)}`
        : tone === 'pending'
          ? 'Not serving new requests'
          : 'Not serving requests',
    steps,
  };
}
