import { app, clipboard, ipcMain, shell } from 'electron';
import path from 'node:path';
import type { Backend } from './backend';
import { HardwareWatch } from './hardware';
import type { desktopUpdates } from './updates';
import type { MainWindow } from './window';
import type { SystemInfo } from '../shared/macos';
import { clipboardText, externalURL, isTrustedSender, softwareUpdateURL } from './security';

function installScript() {
  return path.join(
    app.isPackaged ? process.resourcesPath : app.getAppPath(),
    app.isPackaged ? 'bootstrap' : 'resources',
    'install-runtime.sh',
  );
}

// Every renderer-callable channel. Each call is rejected unless it comes from
// the main frame of our window on the app origin (see security.ts).
export function registerIPC(options: {
  window: MainWindow;
  backend: Backend;
  updates: ReturnType<typeof desktopUpdates>;
  smokeTest: boolean;
  devURL: string | undefined;
}) {
  const { window, backend, updates, smokeTest, devURL } = options;
  const handle = (channel: string, callback: (...args: any[]) => any) => {
    ipcMain.handle(channel, (event, ...args) => {
      if (!isTrustedSender(event, window.webContents, devURL)) throw new Error('Untrusted sender');
      return callback(...args);
    });
  };
  handle('backend:read', (resource) => backend.read(resource));
  handle('backend:act', (action) => {
    if (smokeTest) throw new Error('Native actions are disabled in UI smoke tests');
    return backend.act(action);
  });
  handle('backend:status', () => backend.current);
  handle('backend:install', () => {
    if (smokeTest) throw new Error('Installation is disabled in UI smoke tests');
    return backend.install(installScript());
  });
  handle('backend:cancelInstall', () => backend.cancelInstall());
  handle('app:copy', (text) => {
    clipboard.writeText(clipboardText(text));
  });
  handle('app:external', async (target) => {
    await shell.openExternal(externalURL(target, backend.snapshot?.link?.url));
  });
  // Elsewhere (a development build on Linux, say) the version isn't macOS's, so it is unknown.
  handle('app:system', (): SystemInfo => ({
    macosVersion: process.platform === 'darwin' ? process.getSystemVersion() : '',
  }));
  // A fixed System Settings URL: the renderer chooses no part of it, and the external-link
  // allowlist stays https-only.
  handle('app:software-update', async () => {
    await shell.openExternal(softwareUpdateURL);
  });
  const hardware = new HardwareWatch(
    (signal) => backend.openHardwareEvents(signal),
    (sample) => window.send('hardware:sample', sample),
  );
  window.webContents?.on('did-start-navigation', (details) => {
    if (details.isMainFrame && !details.isSameDocument) hardware.reset();
  });
  window.webContents?.on('render-process-gone', () => hardware.reset());
  handle('hardware:watch', () => {
    if (!smokeTest) hardware.acquire();
  });
  handle('hardware:unwatch', () => hardware.release());
  handle('app:update-status', () => updates.status());
  handle('app:update', () => updates.check());
  handle('app:apply-update', () => updates.apply());
}
