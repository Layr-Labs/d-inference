import { BrowserWindow } from 'electron';
import path from 'node:path';
import type { Route, Snapshot } from '../shared/contracts';
import { isQuitting } from './lifecycle';
import { allowedNavigation, appOrigin } from './security';

// The single app window: sandboxed, no popups, no permissions, no foreign
// navigation. Closing hides it so the menu bar app keeps running.
export class MainWindow {
  private window?: BrowserWindow;
  constructor(
    private devURL: string | undefined,
    private snapshot: () => Snapshot | undefined,
  ) {}
  get webContents() {
    return this.window?.webContents;
  }
  isVisible() {
    return !!this.window?.isVisible();
  }
  send(channel: string, value: unknown) {
    this.window?.webContents.send(channel, value);
  }
  create(hidden = false) {
    const window = new BrowserWindow({
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
    this.window = window;
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', (event, url) => {
      if (!allowedNavigation(url, this.devURL)) event.preventDefault();
    });
    window.webContents.session.setPermissionRequestHandler((_web, _permission, callback) =>
      callback(false),
    );
    window.once('ready-to-show', () => {
      if (!hidden) window.show();
    });
    window.on('close', (event) => {
      if (!isQuitting()) {
        event.preventDefault();
        window.hide();
      }
    });
    window.on('closed', () => {
      if (this.window === window) this.window = undefined;
    });
    void window.loadURL(this.devURL || appOrigin + 'index.html');
  }
  show(route?: Route) {
    if (!this.window) this.create();
    const window = this.window!;
    window.show();
    window.focus();
    const snapshot = this.snapshot();
    if (snapshot) window.webContents.send('backend:state', snapshot);
    if (route) window.webContents.send('app:navigate', route);
  }
}
