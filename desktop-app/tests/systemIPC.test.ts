import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { Backend } from '../src/main/backend';
import type { MainWindow } from '../src/main/window';

const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>();
const openExternal = vi.hoisted(() => vi.fn(async (_url: string) => {}));
vi.mock('electron', () => ({
  app: { isPackaged: false, getAppPath: () => '/app' },
  clipboard: { writeText: () => {} },
  shell: { openExternal },
  ipcMain: { handle: (channel: string, callback: never) => handlers.set(channel, callback) },
}));

const mainFrame = { url: 'darkbloom://app/index.html' };
const webContents = { mainFrame, on: () => {} };
const trusted = { sender: webContents, senderFrame: mainFrame };
const subframe = { sender: webContents, senderFrame: { url: mainFrame.url } };
const foreign = { sender: { mainFrame }, senderFrame: mainFrame };

const platform = process.platform;
const setPlatform = (value: string) => Object.defineProperty(process, 'platform', { value });
beforeEach(async () => {
  handlers.clear();
  openExternal.mockClear();
  Object.assign(process, { getSystemVersion: () => '26.5.1' });
  const { registerIPC } = await import('../src/main/ipc');
  registerIPC({
    window: { webContents, send: () => {} } as unknown as MainWindow,
    backend: {} as Backend,
    updates: {} as never,
    smokeTest: false,
    devURL: undefined,
  });
});
afterEach(() => {
  setPlatform(platform);
  Reflect.deleteProperty(process, 'getSystemVersion');
});

it('rejects the macOS version and Software Update from anything but our main frame', () => {
  for (const event of [subframe, foreign])
    for (const channel of ['app:system', 'app:software-update'])
      expect(() => handlers.get(channel)!(event)).toThrow('Untrusted sender');
  expect(openExternal).not.toHaveBeenCalled();
});

it('reports macOS’s version on a Mac, and no version elsewhere', () => {
  setPlatform('darwin');
  expect(handlers.get('app:system')!(trusted)).toEqual({ macosVersion: '26.5.1' });
  setPlatform('linux');
  expect(handlers.get('app:system')!(trusted)).toEqual({ macosVersion: '' });
});

it('opens only System Settings’ Software Update pane, whatever the renderer passes', async () => {
  await handlers.get('app:software-update')!(trusted, 'https://example.com');
  expect(openExternal).toHaveBeenCalledExactlyOnceWith(
    'x-apple.systempreferences:com.apple.Software-Update-Settings.extension',
  );
});
