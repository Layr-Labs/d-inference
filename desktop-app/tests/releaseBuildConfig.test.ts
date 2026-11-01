import { expect, it } from 'vitest';
import { desktopBuildConfig, releaseTeam } from '../electron-builder';

const credentials = {
  APPLE_ID: 'release@example.com',
  APPLE_APP_SPECIFIC_PASSWORD: 'app-password',
  APPLE_TEAM_ID: releaseTeam,
};
const feed = 'https://github.com/Layr-Labs/d-inference/releases/download/desktop-latest';

it('signs and notarizes a release build with the CLI’s Developer ID team', () => {
  const config = desktopBuildConfig({
    DARKBLOOM_DESKTOP_RELEASE: '1',
    ...credentials,
    DARKBLOOM_DESKTOP_UPDATE_URL: feed,
  });
  expect(config.appId).toBe('io.darkbloom.desktop');
  expect(config.productName).toBe('Darkbloom');
  expect(config.forceCodeSigning).toBe(true);
  expect(config.mac?.notarize).toBe(true);
  expect(config.mac?.artifactName).toBe('${productName}-${version}-${arch}.${ext}');
  expect(config.publish).toEqual({ provider: 'generic', url: feed });
});

it('refuses a release build without an update feed', () => {
  expect(() => desktopBuildConfig({ DARKBLOOM_DESKTOP_RELEASE: '1', ...credentials })).toThrow(
    'needs DARKBLOOM_DESKTOP_UPDATE_URL',
  );
  expect(() =>
    desktopBuildConfig({
      DARKBLOOM_DESKTOP_RELEASE: '1',
      ...credentials,
      DARKBLOOM_DESKTOP_UPDATE_URL: 'http://example.com/feed',
    }),
  ).toThrow('must be an https URL');
});

it('refuses a release build without notarization credentials or for another team', () => {
  expect(() => desktopBuildConfig({ DARKBLOOM_DESKTOP_RELEASE: '1' })).toThrow(
    'needs notarization credentials: APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID',
  );
  expect(() =>
    desktopBuildConfig({
      DARKBLOOM_DESKTOP_RELEASE: '1',
      ...credentials,
      APPLE_TEAM_ID: 'ABCDEFGHIJ',
    }),
  ).toThrow(`team ${releaseTeam}`);
  expect(() =>
    desktopBuildConfig({
      DARKBLOOM_DESKTOP_RELEASE: '1',
      ...credentials,
      DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
      DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
    }),
  ).toThrow('cannot also be a local preview');
});

it('keeps development and preview builds un-notarized and without a feed', () => {
  expect(desktopBuildConfig({}).mac?.notarize).toBe(false);
  expect(desktopBuildConfig({}).forceCodeSigning).toBeUndefined();
  expect(desktopBuildConfig({}).publish).toBeNull();
  const preview = desktopBuildConfig({
    DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
    DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
  });
  expect(preview.mac?.notarize).toBe(false);
  expect(preview.appId).toBe('io.darkbloom.desktop.preview');
});
