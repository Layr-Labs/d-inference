import type { MenuItemConstructorOptions } from 'electron';
import type { Route, Snapshot } from '../shared/contracts';

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
    status: trayStatus(state?.state),
    canStart: state?.state === 'stopped',
    canStop: idle,
    canRestart: idle,
  };
}

// The same words as Home and This Mac: the act is serving, and its status is named for people,
// not echoed from the protocol.
export function trayStatus(state: Snapshot['state'] | undefined): string {
  switch (state) {
    case 'running':
      return 'Serving';
    case 'stopped':
      return 'Stopped';
    case 'starting':
      return 'Starting…';
    case 'draining':
      return 'Finishing requests';
    case 'stale':
      return 'Status unavailable';
    default:
      return 'Connecting…';
  }
}

export interface TrayMenuActions {
  show: (route?: Route) => void;
  start: () => void;
  stop: () => void;
  restart: () => void;
  quit: () => void;
}

export function trayMenuTemplate(
  model: TrayMenuModel,
  actions: TrayMenuActions,
): MenuItemConstructorOptions[] {
  return [
    { label: `Darkbloom — ${model.status}`, enabled: false },
    { label: 'Open Darkbloom', click: () => actions.show() },
    { label: 'Models', click: () => actions.show('models') },
    { label: 'Studio', click: () => actions.show('studio') },
    { label: 'Earnings', click: () => actions.show('earnings') },
    { type: 'separator' },
    { label: 'Start serving', enabled: model.canStart, click: actions.start },
    { label: 'Stop serving', enabled: model.canStop, click: actions.stop },
    { label: 'Restart serving', enabled: model.canRestart, click: actions.restart },
    { type: 'separator' },
    { label: 'Quit Darkbloom', click: actions.quit },
  ];
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
