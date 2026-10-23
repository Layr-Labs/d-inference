import type { Action, DesktopStatus, Route, Snapshot } from '../../../../shared/contracts';
import { operationLabel } from '../../../components/operations/labels';
import { runtimeStep, operationStep, updateStep, linkStep, providerStep } from './readinessSteps';

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
  status: string;
  summary: string;
  steps: ReadinessStep[];
}
export interface ReadinessFacts {
  status: DesktopStatus;
  state: Snapshot;
  update: { required: boolean; available: boolean };
}

const lifecycle: Action['action'][] = ['start', 'switch', 'stop', 'restart', 'update'];
// Next steps from reported facts only; admission and routing policy stay with
// the runtime and coordinator. Linking is advice: it never changes the tone.
export function assessReadiness({ status, state, update }: ReadinessFacts): Readiness {
  if (status.state !== 'ready') {
    const step = runtimeStep(status);
    return {
      tone: step.actions.length ? 'blocked' : 'pending',
      status:
        status.state === 'installing'
          ? 'Setting up Darkbloom'
          : status.state === 'connecting'
            ? 'Connecting to this Mac'
            : status.state === 'missing'
              ? 'Setup required'
              : 'Connection unavailable',
      summary: 'Serving status unavailable',
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
  const primary = steps.find((step) => !['link', 'operation'].includes(step.id));
  const statusLabel =
    tone === 'ready'
      ? 'Ready to serve'
      : !update.required && transitioning && operation
        ? operationLabel(operation)
        : primary?.id === 'start'
          ? 'Stopped'
          : primary?.id === 'stale'
            ? 'Status unavailable'
            : primary?.id === 'crashed'
              ? 'Needs restart'
              : (primary?.title ?? 'Not ready');
  return {
    tone,
    status: statusLabel,
    summary:
      tone === 'ready'
        ? `${loaded.length} ${loaded.length === 1 ? 'model' : 'models'} loaded`
        : tone === 'pending'
          ? 'Not serving new requests'
          : 'Not serving requests',
    steps,
  };
}
