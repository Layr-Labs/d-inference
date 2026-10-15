import type { Action, NativeModel, Operation } from '../../../shared/contracts';
import { modelName } from '../../models/facts';

const actions: Record<Action['action'], { name: string; running: string }> = {
  start: { name: 'Start serving', running: 'Starting to serve' },
  stop: { name: 'Stop serving', running: 'Stopping serving' },
  restart: { name: 'Restart serving', running: 'Restarting serving' },
  switch: { name: 'Model selection', running: 'Changing models' },
  update: { name: 'Darkbloom update', running: 'Updating Darkbloom' },
  diagnose: { name: 'Health check', running: 'Checking this Mac' },
  link: { name: 'Mac linking', running: 'Linking this Mac' },
  unlink: { name: 'Mac unlinking', running: 'Unlinking this Mac' },
  'account-signin': { name: 'Sign-in', running: 'Signing in' },
  'account-signout': { name: 'Sign-out', running: 'Signing out' },
  download: { name: 'Model download', running: 'Downloading model' },
  remove: { name: 'Model removal', running: 'Removing model' },
  cancel: { name: 'Cancellation', running: 'Cancelling' },
  settings: { name: 'Settings', running: 'Saving settings' },
  cooling: { name: 'Fan settings', running: 'Updating fan settings' },
  waitlist: { name: 'Waitlist signup', running: 'Joining the waitlist' },
  autopilot: { name: 'Autopilot setup', running: 'Setting up Autopilot' },
  autopilot_pin: { name: 'Keep in memory', running: 'Keeping models in memory' },
  autopilot_unpin: { name: 'Memory preference', running: 'Updating memory preference' },
  autopilot_pause: { name: 'Autopilot pause', running: 'Pausing Autopilot' },
  autopilot_resume: { name: 'Autopilot resume', running: 'Resuming Autopilot' },
  autopilot_disable: { name: 'Manual mode', running: 'Switching to manual' },
  autopilot_models: { name: 'Model refresh', running: 'Refreshing available models' },
};
const states: Record<Exclude<Operation['state'], 'running'>, string> = {
  succeeded: 'Complete',
  failed: 'Failed',
  cancelled: 'Cancelled',
  interrupted: 'Interrupted',
};
export function operationLabel(operation: Pick<Operation, 'action' | 'state'>): string {
  const action = actions[operation.action];
  // A newer runtime may add an operation before this app updates.
  if (!action)
    return operation.state === 'running' ? 'Working…' : `Action · ${states[operation.state]}`;
  return operation.state === 'running'
    ? action.running
    : `${action.name} · ${states[operation.state]}`;
}

// A download the runtime attributes names its model, with the progress its row shows.
export function operationTitle(operation: Operation, models: NativeModel[]): string {
  if (operation.action !== 'download' || !operation.model) return operationLabel(operation);
  const name = modelName(models, operation.model);
  if (operation.state !== 'running') return `${name} download · ${states[operation.state]}`;
  return operation.progress === undefined
    ? `Downloading ${name}`
    : `Downloading ${name} · ${Math.round(operation.progress * 100)}%`;
}
