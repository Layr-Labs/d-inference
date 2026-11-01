import { autoUpdater } from 'electron-updater';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import type { GUIUpdate } from '../shared/contracts';
import { initialUpdateState, nextUpdateState, updateConfigFile } from './updateFeed';

const checkInterval = 4 * 60 * 60_000;

// The feed electron-builder embedded in this packaged build, if any.
export function readUpdateConfig(resourcesPath: string) {
  try {
    return readFileSync(path.join(resourcesPath, updateConfigFile), 'utf8');
  } catch {
    return undefined;
  }
}

// GUI self-update. When `enabled` is false (no embedded feed, development, or
// UI smoke test) electron-updater is never touched and the state stays
// `unconfigured` instead of erroring on every scheduled check.
export function desktopUpdates(enabled: boolean, beforeInstall: () => void) {
  let state: GUIUpdate = initialUpdateState(enabled);
  if (enabled) {
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.on('checking-for-update', () => {
      state = nextUpdateState({ type: 'checking' });
    });
    autoUpdater.on('update-available', (info) => {
      state = nextUpdateState({ type: 'available', version: info.version });
    });
    autoUpdater.on('update-not-available', () => {
      state = nextUpdateState({ type: 'not-available' });
    });
    autoUpdater.on('update-downloaded', (info) => {
      state = nextUpdateState({ type: 'downloaded', version: info.version });
    });
    autoUpdater.on('error', (error) => {
      state = nextUpdateState({ type: 'error', message: error.message });
    });
  }
  const check = async () => {
    if (enabled)
      await autoUpdater.checkForUpdates().catch((error: Error) => {
        state = nextUpdateState({ type: 'error', message: error.message });
      });
    return state;
  };
  return {
    status: () => state,
    check,
    apply() {
      if (state.state !== 'ready') throw new Error('Update is not ready');
      beforeInstall();
      autoUpdater.quitAndInstall();
    },
    schedule() {
      if (!enabled) return;
      void check();
      setInterval(() => void check(), checkInterval).unref();
    },
  };
}
