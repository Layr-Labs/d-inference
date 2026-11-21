import type { Snapshot } from '../shared/contracts';

// Everything the tray menu shows that depends on provider state. Snapshots
// arrive every couple of seconds; the native menu is rebuilt only when this
// model changes, because replacing an open macOS context menu closes it.
export interface TrayMenuModel {
  status: string;
  canStart: boolean;
  canStop: boolean;
  canRestart: boolean;
}

export function trayMenuModel(state: Snapshot | undefined): TrayMenuModel {
  const idle =
    state?.state === 'running' &&
    !state.operations.some((operation) => operation.state === 'running');
  return {
    status: state?.state || 'Connecting',
    canStart: state?.state === 'stopped',
    canStop: idle,
    canRestart: idle,
  };
}

export function sameTrayMenu(a: TrayMenuModel, b: TrayMenuModel) {
  return (
    a.status === b.status &&
    a.canStart === b.canStart &&
    a.canStop === b.canStop &&
    a.canRestart === b.canRestart
  );
}

export function trayMenuUpdater(render: (model: TrayMenuModel) => void) {
  let last: TrayMenuModel | undefined;
  return (state: Snapshot | undefined) => {
    const next = trayMenuModel(state);
    if (last && sameTrayMenu(last, next)) return;
    last = next;
    render(next);
  };
}

// Click handlers read this at click time, so a menu that was not rebuilt never
// acts on a stale model selection.
export function startableModels(state: Snapshot | undefined) {
  return (
    state?.models.filter((model) => model.serving && model.downloaded).map((model) => model.id) ||
    []
  );
}
