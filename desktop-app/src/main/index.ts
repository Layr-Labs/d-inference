import {
  app,
  BrowserWindow,
  clipboard,
  ipcMain,
  Menu,
  Notification,
  nativeImage,
  net,
  protocol,
  shell,
  Tray,
} from 'electron';
import { autoUpdater } from 'electron-updater';
import path from 'node:path';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { Backend } from './backend';
import type { GUIUpdate, Route } from '../shared/contracts';

protocol.registerSchemesAsPrivileged([
  { scheme: 'darkbloom', privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);
const backend = new Backend(app.isPackaged);
const uiSmokeTest = process.argv.includes('--ui-smoke-test');
if (uiSmokeTest)
  backend.current = { state: 'missing', message: 'UI smoke test: native backend disabled.' };
let window: BrowserWindow | undefined;
let tray: Tray;
let quitting = false;
let notifiedOperation: string | undefined;
let guiUpdate: GUIUpdate = { state: 'idle' };
const devURL = !app.isPackaged ? process.env.DARKBLOOM_DEV_URL : undefined;
function show(route?: Route) {
  if (!window) createWindow();
  window!.show();
  window!.focus();
  if (backend.snapshot) window!.webContents.send('backend:state', backend.snapshot);
  if (route) window!.webContents.send('app:navigate', route);
}
function createWindow() {
  window = new BrowserWindow({
    width: 1320,
    height: 880,
    minWidth: 940,
    minHeight: 650,
    backgroundColor: '#070707',
    title: 'Darkbloom',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 20, y: 22 },
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
    show: false,
  });
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  window.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(devURL || 'darkbloom://app/')) event.preventDefault();
  });
  window.webContents.session.setPermissionRequestHandler((_web, _permission, callback) =>
    callback(false),
  );
  window.once('ready-to-show', () => {
    if (!process.argv.includes('--hidden')) window?.show();
  });
  window.on('close', (event) => {
    if (!quitting) {
      event.preventDefault();
      window?.hide();
    }
  });
  window.on('closed', () => {
    window = undefined;
  });
  void window.loadURL(devURL || 'darkbloom://app/index.html');
}
function menu() {
  const state = backend.snapshot;
  tray.setToolTip(`Darkbloom · ${state?.state || 'Connecting'}`);
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: `Darkbloom — ${state?.state || 'Connecting'}`, enabled: false },
      { label: 'Open Darkbloom', click: () => show() },
      { label: 'Models', click: () => show('models') },
      { label: 'Studio', click: () => show('studio') },
      { type: 'separator' },
      {
        label: 'Start provider',
        enabled: !!state && state.state === 'stopped',
        click: () => {
          const models =
            state?.models
              .filter((model) => model.serving && model.downloaded)
              .map((model) => model.id) || [];
          if (models.length)
            void backend.act({ action: 'start', models }).catch(() => show('models'));
          else show('models');
        },
      },
      {
        label: 'Stop provider',
        enabled:
          state?.state === 'running' &&
          !state.operations.some((operation) => operation.state === 'running'),
        click: () => {
          void backend.act({ action: 'stop' }).catch(() => show());
        },
      },
      {
        label: 'Restart provider',
        enabled:
          state?.state === 'running' &&
          !state.operations.some((operation) => operation.state === 'running'),
        click: () => {
          void backend.act({ action: 'restart' }).catch(() => show());
        },
      },
      { type: 'separator' },
      {
        label: 'Quit Darkbloom',
        click: () => {
          quitting = true;
          app.quit();
        },
      },
    ]),
  );
}
function trusted(event: Electron.IpcMainInvokeEvent) {
  const url = event.senderFrame?.url;
  if (
    event.sender !== window?.webContents ||
    event.senderFrame !== event.sender.mainFrame ||
    !url ||
    !(devURL
      ? new URL(url).origin === new URL(devURL).origin
      : new URL(url).protocol === 'darkbloom:' && new URL(url).hostname === 'app')
  )
    throw new Error('Untrusted sender');
}
function handle(channel: string, callback: (...args: any[]) => any) {
  ipcMain.handle(channel, (event, ...args) => {
    trusted(event);
    return callback(...args);
  });
}
if (!app.requestSingleInstanceLock()) app.quit();
else {
  app.on('second-instance', () => show());
  app.whenReady().then(async () => {
    if (app.isPackaged && !uiSmokeTest) {
      const preferencePath = path.join(app.getPath('userData'), 'login-initialized.json');
      try {
        await readFile(preferencePath);
      } catch {
        app.setLoginItemSettings({ openAtLogin: true, args: ['--hidden'] });
        await mkdir(app.getPath('userData'), { recursive: true });
        await writeFile(preferencePath, '{"initialized":true}', { mode: 0o600 });
      }
    }
    protocol.handle('darkbloom', (request) => {
      const url = new URL(request.url);
      const root = path.join(__dirname, 'renderer');
      const file = path.resolve(root, '.' + decodeURIComponent(url.pathname));
      if (url.host !== 'app' || !file.startsWith(root + path.sep))
        return new Response('Forbidden', { status: 403 });
      return net.fetch(pathToFileURL(file).toString()).then((response) => {
        const headers = new Headers(response.headers);
        headers.set(
          'Content-Security-Policy',
          "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-src 'none'",
        );
        return new Response(response.body, { status: response.status, headers });
      });
    });
    const icon = nativeImage.createFromPath(path.join(__dirname, 'trayTemplate.png'));
    icon.setTemplateImage(true);
    tray = new Tray(icon);
    tray.on('double-click', () => show());
    menu();
    createWindow();
    Menu.setApplicationMenu(
      Menu.buildFromTemplate([
        {
          label: 'Darkbloom',
          submenu: [
            { role: 'about' },
            { type: 'separator' },
            { label: 'Settings', accelerator: 'CmdOrCtrl+,', click: () => show('settings') },
            { role: 'hide' },
            {
              label: 'Quit',
              accelerator: 'CmdOrCtrl+Q',
              click: () => {
                quitting = true;
                app.quit();
              },
            },
          ],
        },
        { role: 'editMenu' },
        { role: 'windowMenu' },
      ]),
    );
    handle('backend:read', (resource) => backend.read(resource));
    handle('backend:act', (action) => {
      if (uiSmokeTest) throw new Error('Native actions are disabled in UI smoke tests');
      return backend.act(action);
    });
    handle('backend:status', () => backend.current);
    handle('backend:install', () => {
      if (uiSmokeTest) throw new Error('Installation is disabled in UI smoke tests');
      return backend.install(
        path.join(
          app.isPackaged ? process.resourcesPath : app.getAppPath(),
          app.isPackaged ? 'bootstrap' : 'resources',
          'install-runtime.sh',
        ),
      );
    });
    handle('app:copy', (text) => {
      if (typeof text !== 'string' || text.length > 65536)
        throw new Error('Invalid clipboard value');
      clipboard.writeText(text);
    });
    handle('app:external', async (target) => {
      const links: Record<string, string> = {
        console: 'https://console.darkbloom.dev',
        docs: 'https://docs.darkbloom.dev',
        community: 'https://github.com/Layr-Labs/d-inference/discussions',
        terms: 'https://www.darkbloom.ai/terms',
        privacy: 'https://www.darkbloom.ai/privacy',
      };
      const url = target === 'link' ? backend.snapshot?.link?.url : links[target];
      if (
        !url ||
        new URL(url).protocol !== 'https:' ||
        !['console.darkbloom.dev', 'docs.darkbloom.dev', 'www.darkbloom.ai', 'github.com'].includes(
          new URL(url).hostname,
        )
      )
        throw new Error('Unsupported link');
      await shell.openExternal(url);
    });
    handle('app:update', async () => {
      if (app.isPackaged && !uiSmokeTest)
        await autoUpdater.checkForUpdates().catch((error) => {
          guiUpdate = { state: 'error', message: error.message };
        });
      return guiUpdate;
    });
    handle('app:apply-update', () => {
      if (guiUpdate.state !== 'ready') throw new Error('Update is not ready');
      quitting = true;
      autoUpdater.quitAndInstall();
    });
    autoUpdater.autoDownload = true;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.on('checking-for-update', () => {
      guiUpdate = { state: 'checking' };
    });
    autoUpdater.on('update-available', (info) => {
      guiUpdate = { state: 'downloading', version: info.version };
    });
    autoUpdater.on('update-not-available', () => {
      guiUpdate = { state: 'idle' };
    });
    autoUpdater.on('update-downloaded', (info) => {
      guiUpdate = { state: 'ready', version: info.version };
    });
    autoUpdater.on('error', (error) => {
      guiUpdate = { state: 'error', message: error.message };
    });
    backend.on('state', (state) => {
      if (window?.isVisible()) window.webContents.send('backend:state', state);
      menu();
      const operation = state.operations[0];
      if (
        operation?.state === 'failed' &&
        operation.id !== notifiedOperation &&
        !window?.isVisible() &&
        Notification.isSupported()
      ) {
        notifiedOperation = operation.id;
        const notification = new Notification({
          title: 'Darkbloom needs attention',
          body: 'An operation could not finish. Open Darkbloom for details.',
        });
        notification.on('click', () => show());
        notification.show();
      }
    });
    backend.on('status', (state) => window?.webContents.send('backend:status', state));
    if (!uiSmokeTest && !devURL?.includes('preview')) void backend.watch();
    if (app.isPackaged && !uiSmokeTest) {
      void autoUpdater.checkForUpdates().catch(() => {});
      setInterval(
        () => void autoUpdater.checkForUpdates().catch(() => {}),
        4 * 60 * 60_000,
      ).unref();
    }
  });
  app.on('activate', () => show());
  app.on('window-all-closed', () => {});
  app.on('before-quit', () => {
    quitting = true;
    backend.stop();
  });
}
