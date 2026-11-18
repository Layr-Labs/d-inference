import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { expect, it } from 'vitest';
import { desktopBuildConfig, entitlements } from '../electron-builder';

const feed = 'https://github.com/Layr-Labs/d-inference/releases/download/desktop-latest';
const release = { DARKBLOOM_DESKTOP_RELEASE: '1', DARKBLOOM_DESKTOP_UPDATE_URL: feed };

function entitlementKeys(file: string) {
  const text = readFileSync(file, 'utf8');
  return [...text.matchAll(/<key>([^<]+)<\/key>\s*<(true|false)\/>/g)].map(([, key, value]) => [
    key,
    value,
  ]);
}

it('builds a release unsigned, with the feed, whatever certificates the machine has', () => {
  const config = desktopBuildConfig(release);
  expect(config.appId).toBe('io.darkbloom.desktop');
  expect(config.productName).toBe('Darkbloom');
  // release-desktop.yml signs and notarizes the app in another job.
  expect(config.mac?.identity).toBeNull();
  expect(config.mac?.notarize).toBe(false);
  expect(config.mac?.sign).toBeUndefined();
  expect(config.forceCodeSigning).toBeUndefined();
  expect(config.mac?.hardenedRuntime).toBe(true);
  expect(config.mac?.artifactName).toBe('${productName}-${version}-${arch}.${ext}');
  expect(config.publish).toEqual({ provider: 'generic', url: feed });
});

it('needs no signing or notarization credential for a release build', () => {
  // The job that builds holds none; credentials in its environment change nothing.
  const withCredentials = desktopBuildConfig({
    ...release,
    APPLE_ID: 'release@example.com',
    APPLE_APP_SPECIFIC_PASSWORD: 'app-password',
    APPLE_TEAM_ID: 'ABCDEFGHIJ',
    CSC_NAME: '0123456789ABCDEF0123456789ABCDEF01234567',
  });
  expect(withCredentials).toEqual(desktopBuildConfig(release));
});

it('refuses a release build without an update feed', () => {
  expect(() => desktopBuildConfig({ DARKBLOOM_DESKTOP_RELEASE: '1' })).toThrow(
    'needs DARKBLOOM_DESKTOP_UPDATE_URL',
  );
  expect(() =>
    desktopBuildConfig({
      DARKBLOOM_DESKTOP_RELEASE: '1',
      DARKBLOOM_DESKTOP_UPDATE_URL: 'http://example.com/feed',
    }),
  ).toThrow('must be an https URL');
});

it('refuses a release build that is also a local preview', () => {
  expect(() =>
    desktopBuildConfig({
      ...release,
      DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
      DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
    }),
  ).toThrow('cannot also be a local preview');
});

it('keeps development and preview builds un-notarized and without a feed', () => {
  expect(desktopBuildConfig({}).mac?.notarize).toBe(false);
  expect(desktopBuildConfig({}).forceCodeSigning).toBeUndefined();
  expect(desktopBuildConfig({}).publish).toBeNull();
  // A development build may still be signed with a certificate the machine has.
  expect(desktopBuildConfig({}).mac).not.toHaveProperty('identity');
  const preview = desktopBuildConfig({
    DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
    DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
  });
  expect(preview.mac?.notarize).toBe(false);
  expect(preview.forceCodeSigning).toBe(true);
  expect(preview.mac?.sign).toBeTypeOf('function');
  expect(preview.appId).toBe('io.darkbloom.desktop.preview');
});

it('signs every build with the same entitlements as the release signer', () => {
  for (const env of [{}, release]) {
    const mac = desktopBuildConfig(env).mac;
    expect(mac?.entitlements).toBe(entitlements);
    expect(mac?.entitlementsInherit).toBe(entitlements);
  }
  // scripts/sign-desktop-app.py signs the release with this file; electron-builder would use its
  // own template. They must grant the same entitlements, so an electron-builder upgrade that
  // changes the template fails here instead of changing only one of the two signers.
  const template = createRequire(import.meta.url).resolve(
    'app-builder-lib/templates/entitlements.mac.plist',
  );
  const granted = entitlementKeys(entitlements);
  expect(granted).toEqual([
    ['com.apple.security.cs.allow-jit', 'true'],
    ['com.apple.security.cs.allow-unsigned-executable-memory', 'true'],
    ['com.apple.security.cs.disable-library-validation', 'true'],
  ]);
  expect(granted).toEqual(entitlementKeys(template));
});
