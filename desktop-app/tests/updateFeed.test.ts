import { expect, it } from 'vitest';
import {
  feedConfigured,
  initialUpdateState,
  nextUpdateState,
  publishConfig,
  unconfiguredUpdate,
  updateChecksEnabled,
  updateFeedEnv,
} from '../src/main/updateFeed';
import { desktopBuildConfig } from '../electron-builder';

const feed = 'https://updates.example.test/desktop';
// The exact app-update.yml electron-builder writes for a generic feed.
const genericYml = `provider: generic\nurl: ${feed}\nupdaterCacheDirName: darkbloom-desktop-updater\n`;
// What the former `publish: { provider: github, ... }` embedded: provider releases.
const githubYml =
  'owner: Layr-Labs\nrepo: d-inference\nprovider: github\nreleaseType: draft\nupdaterCacheDirName: darkbloom-desktop-updater\n';

it('embeds no update feed unless one is configured at build time', () => {
  expect(publishConfig(undefined)).toBeNull();
  expect(publishConfig('')).toBeNull();
  expect(publishConfig('  ')).toBeNull();
  expect(publishConfig(feed)).toEqual({ provider: 'generic', url: feed });
  expect(() => publishConfig('http://updates.example.test/desktop')).toThrow(updateFeedEnv);
  expect(() => publishConfig('not a url')).toThrow(updateFeedEnv);
});

it('never points the build at the provider release repository', () => {
  // `publish: null` (not undefined) stops electron-builder from inferring a
  // GitHub feed from GH_TOKEN/GITHUB_TOKEN.
  const unset = desktopBuildConfig({ GH_TOKEN: 'token' });
  expect(unset.publish).toBeNull();
  expect(JSON.stringify(unset)).not.toMatch(/github/i);
  expect(desktopBuildConfig({ [updateFeedEnv]: feed }).publish).toEqual({
    provider: 'generic',
    url: feed,
  });
  expect(unset.appId).toBe('io.darkbloom.desktop');
  expect(unset.mac?.hardenedRuntime).toBe(true);
});

it('treats only an embedded https generic feed as configured', () => {
  expect(feedConfigured(undefined)).toBe(false);
  expect(feedConfigured('')).toBe(false);
  expect(feedConfigured(genericYml)).toBe(true);
  expect(feedConfigured(`provider: 'generic'\nurl: '${feed}'\n`)).toBe(true);
  expect(feedConfigured(githubYml)).toBe(false);
  expect(feedConfigured('provider: generic\nurl: http://updates.example.test/\n')).toBe(false);
  expect(feedConfigured('provider: generic\n')).toBe(false);
});

it('checks for updates only in a packaged, non-smoke build with a feed', () => {
  const packaged = { packaged: true, smokeTest: false, config: genericYml };
  expect(updateChecksEnabled(packaged)).toBe(true);
  expect(updateChecksEnabled({ ...packaged, config: undefined })).toBe(false);
  expect(updateChecksEnabled({ ...packaged, config: githubYml })).toBe(false);
  expect(updateChecksEnabled({ ...packaged, packaged: false })).toBe(false);
  expect(updateChecksEnabled({ ...packaged, smokeTest: true })).toBe(false);
});

it('reports an explicit unconfigured state instead of a recurring error', () => {
  expect(initialUpdateState(false)).toEqual(unconfiguredUpdate);
  expect(unconfiguredUpdate).toEqual({
    state: 'unconfigured',
    message: 'Desktop app updates are not configured for this build.',
  });
  expect(initialUpdateState(true)).toEqual({ state: 'idle' });
});

it('maps updater events to the GUI update state', () => {
  expect(nextUpdateState({ type: 'checking' })).toEqual({ state: 'checking' });
  expect(nextUpdateState({ type: 'available', version: '0.2.0' })).toEqual({
    state: 'downloading',
    version: '0.2.0',
  });
  expect(nextUpdateState({ type: 'not-available' })).toEqual({ state: 'idle' });
  expect(nextUpdateState({ type: 'downloaded', version: '0.2.0' })).toEqual({
    state: 'ready',
    version: '0.2.0',
  });
  expect(nextUpdateState({ type: 'error', message: 'offline' })).toEqual({
    state: 'error',
    message: 'offline',
  });
});
