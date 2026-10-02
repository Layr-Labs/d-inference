import path from 'node:path';
import { expect, it } from 'vitest';
import {
  allowedNavigation,
  clipboardText,
  externalURL,
  isTrustedSender,
  rendererFile,
} from '../src/main/security';

const mainFrame = { url: 'darkbloom://app/index.html' };
const window = { mainFrame };

it('accepts IPC only from the main frame of our window on the app origin', () => {
  expect(isTrustedSender({ sender: window, senderFrame: mainFrame }, window)).toBe(true);
  // another webContents
  expect(isTrustedSender({ sender: { mainFrame }, senderFrame: mainFrame }, window)).toBe(false);
  // no window yet
  expect(isTrustedSender({ sender: window, senderFrame: mainFrame }, undefined)).toBe(false);
  // a subframe
  const child = { url: 'darkbloom://app/index.html' };
  expect(isTrustedSender({ sender: window, senderFrame: child }, window)).toBe(false);
  // destroyed frame
  expect(isTrustedSender({ sender: window, senderFrame: null }, window)).toBe(false);
  // wrong origin in the main frame
  const remote = { url: 'https://evil.example/' };
  expect(
    isTrustedSender({ sender: { mainFrame: remote }, senderFrame: remote }, { mainFrame: remote }),
  ).toBe(false);
});

it('uses the development origin only when a development URL is set', () => {
  const dev = { url: 'http://127.0.0.1:4318/?preview' };
  const devWindow = { mainFrame: dev };
  expect(isTrustedSender({ sender: devWindow, senderFrame: dev }, devWindow)).toBe(false);
  expect(
    isTrustedSender({ sender: devWindow, senderFrame: dev }, devWindow, 'http://127.0.0.1:4318/'),
  ).toBe(true);
  expect(
    isTrustedSender({ sender: window, senderFrame: mainFrame }, window, 'http://127.0.0.1:4318/'),
  ).toBe(false);
  expect(allowedNavigation('darkbloom://app/index.html')).toBe(true);
  expect(allowedNavigation('https://evil.example/')).toBe(false);
  expect(allowedNavigation('http://127.0.0.1:4318/x', 'http://127.0.0.1:4318/')).toBe(true);
});

it('serves only files under the renderer root on the app host', () => {
  const root = path.resolve('/opt/darkbloom/renderer');
  expect(rendererFile(root, 'darkbloom://app/index.html')).toBe(path.join(root, 'index.html'));
  expect(rendererFile(root, 'darkbloom://app/assets/a.js')).toBe(path.join(root, 'assets/a.js'));
  expect(rendererFile(root, 'darkbloom://other/index.html')).toBeUndefined();
  expect(rendererFile(root, 'darkbloom://app/..%2fmain.cjs')).toBeUndefined();
  // The URL parser collapses encoded dot segments at the root, so this stays inside.
  expect(rendererFile(root, 'darkbloom://app/%2e%2e/%2e%2e/etc/passwd')).toBe(
    path.join(root, 'etc/passwd'),
  );
  expect(rendererFile(root, 'darkbloom://app/')).toBeUndefined();
});

it('opens only allowlisted https links', () => {
  expect(externalURL('docs', undefined)).toBe('https://docs.darkbloom.dev');
  expect(externalURL('link', 'https://console.darkbloom.dev/link?code=1')).toBe(
    'https://console.darkbloom.dev/link?code=1',
  );
  expect(() => externalURL('link', undefined)).toThrow('Unsupported link');
  expect(() => externalURL('link', 'http://console.darkbloom.dev/')).toThrow('Unsupported link');
  expect(() => externalURL('link', 'https://evil.example/')).toThrow('Unsupported link');
  expect(() => externalURL('toString', undefined)).toThrow('Unsupported link');
  expect(() => externalURL('__proto__', undefined)).toThrow('Unsupported link');
});

it('bounds clipboard writes', () => {
  expect(clipboardText('key')).toBe('key');
  expect(() => clipboardText(42)).toThrow('Invalid clipboard value');
  expect(() => clipboardText('x'.repeat(65537))).toThrow('Invalid clipboard value');
});
