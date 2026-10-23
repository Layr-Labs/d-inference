import { expect, it } from 'vitest';
import { desktopBuildConfig, releaseTeam } from '../electron-builder';

const credentials = {
  APPLE_ID: 'release@example.com',
  APPLE_APP_SPECIFIC_PASSWORD: 'app-password',
  APPLE_TEAM_ID: releaseTeam,
};

it('signs and notarizes a release build with the CLI’s Developer ID team', () => {
  const config = desktopBuildConfig({ DARKBLOOM_DESKTOP_RELEASE: '1', ...credentials });
  expect(config.appId).toBe('io.darkbloom.desktop');
  expect(config.productName).toBe('Darkbloom');
  expect(config.forceCodeSigning).toBe(true);
  expect(config.mac?.notarize).toBe(true);
  expect(config.mac?.artifactName).toBe('${productName}-${version}-${arch}.${ext}');
  // No update feed unless one is configured.
  expect(config.publish).toBeNull();
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

it('keeps development and preview builds un-notarized', () => {
  expect(desktopBuildConfig({}).mac?.notarize).toBe(false);
  expect(desktopBuildConfig({}).forceCodeSigning).toBeUndefined();
  const preview = desktopBuildConfig({
    DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
    DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
  });
  expect(preview.mac?.notarize).toBe(false);
  expect(preview.appId).toBe('io.darkbloom.desktop.preview');
});
