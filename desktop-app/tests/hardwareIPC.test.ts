import { beforeEach, expect, it, vi } from 'vitest';
import type { Backend } from '../src/main/backend';
import type { MainWindow } from '../src/main/window';
import type { Resource } from '../src/shared/contracts';

const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>();
vi.mock('electron', () => ({
  app: { isPackaged: false, getAppPath: () => '/app' },
  clipboard: { writeText: () => {} },
  shell: { openExternal: async () => {} },
  ipcMain: { handle: (channel: string, callback: never) => handlers.set(channel, callback) },
}));

const mainFrame = { url: 'darkbloom://app/index.html' };
const listeners = new Map<string, (details?: unknown) => void>();
const webContents = {
  mainFrame,
  on: (event: string, callback: (details?: unknown) => void) => listeners.set(event, callback),
};
const trusted = { sender: webContents, senderFrame: mainFrame };
const subframe = { sender: webContents, senderFrame: { url: mainFrame.url } };
const foreign = { sender: { mainFrame }, senderFrame: mainFrame };

let signals: AbortSignal[];
beforeEach(async () => {
  handlers.clear();
  listeners.clear();
  signals = [];
  const { registerIPC } = await import('../src/main/ipc');
  const backend = {
    openHardwareEvents: (signal: AbortSignal) => {
      signals.push(signal);
      return new Promise(() => {});
    },
  } as unknown as Backend;
  registerIPC({
    window: { webContents, send: () => {} } as unknown as MainWindow,
    backend,
    updates: {} as never,
    smokeTest: false,
    devURL: undefined,
  });
});

it('rejects hardware subscriptions from anything but our main frame', () => {
  for (const event of [subframe, foreign])
    for (const channel of ['hardware:watch', 'hardware:unwatch'])
      expect(() => handlers.get(channel)!(event)).toThrow('Untrusted sender');
  expect(signals).toHaveLength(0);
});

it('streams while the renderer holds a subscription and stops after the last release', () => {
  handlers.get('hardware:watch')!(trusted);
  handlers.get('hardware:watch')!(trusted);
  expect(signals).toHaveLength(1);
  handlers.get('hardware:unwatch')!(trusted);
  expect(signals[0].aborted).toBe(false);
  handlers.get('hardware:unwatch')!(trusted);
  expect(signals[0].aborted).toBe(true);
});

it('drops subscriptions a reloaded or crashed renderer can no longer release', () => {
  handlers.get('hardware:watch')!(trusted);
  listeners.get('did-start-navigation')!({ isMainFrame: true, isSameDocument: true });
  expect(signals[0].aborted).toBe(false);
  listeners.get('did-start-navigation')!({ isMainFrame: true, isSameDocument: false });
  expect(signals[0].aborted).toBe(true);
  handlers.get('hardware:watch')!(trusted);
  listeners.get('render-process-gone')!();
  expect(signals[1].aborted).toBe(true);
});

it('allowlists the hardware snapshot but not its event stream as a read', async () => {
  const { Backend } = await import('../src/main/backend');
  const backend = new Backend(false);
  await expect(backend.read('hardware')).rejects.toThrow('Runtime is not connected');
  expect(() => backend.read('hardware/events' as Resource)).toThrow('Unknown resource');
  await expect(backend.openHardwareEvents(new AbortController().signal)).rejects.toThrow(
    'Runtime is not connected',
  );
});
