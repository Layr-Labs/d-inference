import { app } from 'electron';
import path from 'node:path';
import type { Route } from '../shared/contracts';
import { installApplicationMenu } from './appMenu';
import { Backend } from './backend';
import { registerIPC } from './ipc';
import { prepareQuit } from './lifecycle';
import { initializeLoginItem, launchedHidden } from './loginLaunch';
import { failedOperationNotifier } from './notifications';
import { registerAppScheme, serveRenderer } from './protocol';
import { createTray } from './tray';
import { updateChecksEnabled } from './updateFeed';
import { desktopUpdates, readUpdateConfig } from './updates';
import { MainWindow } from './window';

registerAppScheme();
const backend = new Backend(app.isPackaged);
const uiSmokeTest = process.argv.includes('--ui-smoke-test');
if (uiSmokeTest)
  backend.current = { state: 'missing', message: 'UI smoke test: native backend disabled.' };
const devURL = !app.isPackaged ? process.env.DARKBLOOM_DEV_URL : undefined;
const window = new MainWindow(devURL, () => backend.snapshot);
const show = (route?: Route) => window.show(route);

if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => show());
  app.whenReady().then(async () => {
    const startHidden = launchedHidden(app);
    if (app.isPackaged && !uiSmokeTest) await initializeLoginItem(app);
    serveRenderer(path.join(__dirname, 'renderer'));
    const updateTray = createTray(backend, show);
    window.create(startHidden);
    installApplicationMenu(show);
    const updates = desktopUpdates(
      updateChecksEnabled({
        packaged: app.isPackaged,
        smokeTest: uiSmokeTest,
        config: app.isPackaged ? readUpdateConfig(process.resourcesPath) : undefined,
      }),
      prepareQuit,
    );
    registerIPC({ window, backend, updates, smokeTest: uiSmokeTest, devURL });
    const notify = failedOperationNotifier(() => show());
    backend.on('state', (state) => {
      if (window.isVisible()) window.send('backend:state', state);
      updateTray(state);
      notify(state, window.isVisible());
    });
    backend.on('status', (state) => window.send('backend:status', state));
    if (!uiSmokeTest && !devURL?.includes('preview')) void backend.watch();
    updates.schedule();
  });
  app.on('activate', () => show());
  app.on('window-all-closed', () => {});
  app.on('before-quit', () => {
    prepareQuit();
    backend.stop();
  });
}
