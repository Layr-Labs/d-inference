// @vitest-environment jsdom
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, expect, it, vi } from 'vitest';
import { externalURL } from '../src/main/security';

afterEach(() => vi.restoreAllMocks());

// The device-link URL the production coordinator returns (CONSOLE_URL + /link).
const deviceLink = 'https://console.darkbloom.dev/link?purpose=desktop_account';

// Every link target the renderer passes to openExternal, read from its source.
function rendererTargets() {
  const root = path.resolve('src/renderer');
  const targets = new Set<string>();
  for (const file of readdirSync(root, { recursive: true, encoding: 'utf8' })) {
    if (!/\.tsx?$/.test(file)) continue;
    const source = readFileSync(path.join(root, file), 'utf8');
    for (const [, target] of source.matchAll(/<External target="(\w+)"/g)) targets.add(target);
    for (const [, target] of source.matchAll(/openExternal\('(\w+)'\)/g)) targets.add(target);
  }
  const social = readFileSync(path.join(root, 'components/SocialLinks.tsx'), 'utf8');
  for (const [, target] of social.matchAll(/\{ id: '(\w+)'/g)) targets.add(target);
  return [...targets].sort();
}

it('opens every link the renderer uses in the signed app', () => {
  const targets = rendererTargets();
  expect(targets).toEqual(['console', 'docs', 'github', 'link', 'privacy', 'slack', 'terms', 'x']);
  for (const target of targets) expect(externalURL(target, deviceLink)).toMatch(/^https:\/\//);
  expect(externalURL('docs', deviceLink)).toBe('https://docs.darkbloom.dev');
});

it('still rejects targets outside the shared map', () => {
  for (const target of ['guide', 'toString', 'https://docs.darkbloom.dev', undefined])
    expect(() => externalURL(target, deviceLink)).toThrow('Unsupported link');
});

it('opens the same destinations in a new tab in the browser preview', async () => {
  // Unlinked, so the preview's link action shows a device-link code.
  window.history.replaceState(null, '', '/?preview&account=unlinked');
  const { previewAPI } = await import('../src/renderer/preview');
  const open = vi.spyOn(window, 'open').mockReturnValue(null);
  await previewAPI.openExternal('docs');
  expect(open).toHaveBeenLastCalledWith('https://docs.darkbloom.dev', '_blank', 'noopener');
  await previewAPI.openExternal('terms');
  expect(open).toHaveBeenLastCalledWith('https://www.darkbloom.ai/terms', '_blank', 'noopener');
  await previewAPI.openExternal('link');
  expect(open).toHaveBeenCalledTimes(2);
  await previewAPI.act({ action: 'link' });
  await previewAPI.openExternal('link');
  expect(open).toHaveBeenLastCalledWith('https://console.darkbloom.dev/link', '_blank', 'noopener');
});
