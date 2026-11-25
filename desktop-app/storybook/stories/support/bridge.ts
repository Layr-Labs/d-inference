import type {
  Action,
  DesktopAPI,
  DesktopStatus,
  Operation,
  Route,
  Snapshot,
} from '../../src/after/desktop-app/src/shared/contracts';
import type { SystemInfo } from '../../src/after/desktop-app/src/shared/macos';

export type Version = 'before' | 'after';
interface Handlers {
  read?: (resource: string) => Promise<unknown>;
  act?: (action: Action) => Promise<Operation>;
  copy?: (text: string) => Promise<void>;
  status?: () => Promise<unknown>;
  /** The native installer (`api.install`); resolves by default. */
  install?: () => Promise<void>;
  /** This Mac's macOS version as the main process reads it (`api.system`); 27.0 by default. */
  macosVersion?: string;
  /** Replaces `api.system` entirely (e.g. to reject, as when the version can't be read). */
  system?: () => Promise<SystemInfo>;
}

export const defaultMacOS = '27.0';

export const succeeded = (action: Action['action']): Operation => ({
  id: `${action}-${Math.random().toString(36).slice(2, 8)}`,
  action,
  state: 'succeeded',
  started_at: Math.floor(Date.now() / 1000),
  message: '',
  cancellable: false,
});

// One mock native bridge per version. Stories configure it, and Compare shows what each version
// sent to the "runtime".
function bridge() {
  let handlers: Handlers = {};
  const listeners = new Set<() => void>();
  // What the app subscribed to with onStatus / onState, so a story can push the main process's
  // status changes and snapshots the way the real preload does.
  const statusListeners = new Set<(status: DesktopStatus) => void>();
  const stateListeners = new Set<(state: Snapshot) => void>();
  // App subscribes with onNavigate (the menu bar's "Models", "Studio"…); stories use it to open
  // a page inside the full app shell.
  const navigateListeners = new Set<(route: Route) => void>();
  const log: string[] = [];
  const record = (line: string) => {
    log.push(line);
    listeners.forEach((listener) => listener());
  };
  const api = {
    read: (resource: string) =>
      handlers.read ? handlers.read(resource) : Promise.reject(new Error('Unavailable in Storybook')),
    act: (action: Action) => {
      record(JSON.stringify(action));
      return handlers.act ? handlers.act(action) : Promise.resolve(succeeded(action.action));
    },
    status: () => (handlers.status ? handlers.status() : Promise.resolve({ state: 'ready' })),
    install: () => {
      record('install (native installer)');
      return handlers.install ? handlers.install() : Promise.resolve();
    },
    cancelInstall: async () => record('cancelInstall'),
    openExternal: async (target: string) => record(`openExternal ${target}`),
    system: () =>
      handlers.system ? handlers.system() : Promise.resolve({ macosVersion: handlers.macosVersion ?? defaultMacOS }),
    openSoftwareUpdate: async () => record('openSoftwareUpdate'),
    copy: (text: string) => {
      const model = text.match(/"model":"[^"]+"/)?.[0];
      record(`copied ${model ? `example request with ${model}` : text.slice(0, 48)}`);
      return handlers.copy ? handlers.copy(text) : Promise.resolve();
    },
    updateStatus: async () => ({ state: 'unconfigured', message: 'Storybook preview' }),
    checkUpdate: async () => {},
    applyUpdate: async () => {},
    onState: (listener: (state: Snapshot) => void) => {
      stateListeners.add(listener);
      return () => void stateListeners.delete(listener);
    },
    onStatus: (listener: (status: DesktopStatus) => void) => {
      statusListeners.add(listener);
      return () => void statusListeners.delete(listener);
    },
    onNavigate: (listener: (route: Route) => void) => {
      navigateListeners.add(listener);
      return () => void navigateListeners.delete(listener);
    },
    onHardware: () => () => {},
  } as unknown as DesktopAPI;
  return {
    api,
    log,
    record,
    subscribe(listener: () => void) {
      listeners.add(listener);
      return () => void listeners.delete(listener);
    },
    /** Push a desktop status, as the main process does over `backend:status`. */
    pushStatus(status: DesktopStatus) {
      statusListeners.forEach((listener) => listener(status));
    },
    /** Push a snapshot, as the main process does over `backend:state`. */
    pushState(state: Snapshot) {
      stateListeners.forEach((listener) => listener(state));
    },
    /** Open a page, as the main process does when a menu bar item is chosen. */
    navigate(route: Route) {
      navigateListeners.forEach((listener) => listener(route));
    },
    reset(next: Handlers = {}) {
      handlers = next;
      log.length = 0;
      listeners.forEach((listener) => listener());
    },
  };
}

export const bridges = { before: bridge(), after: bridge() };
export const resetBridges = (handlers: Handlers = {}) => {
  bridges.before.reset(handlers);
  bridges.after.reset(handlers);
};
