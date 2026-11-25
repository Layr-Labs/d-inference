import type { Configuration } from 'electron-builder';
import { signAsync } from '@electron/osx-sign';
import { publishConfig, updateFeedEnv } from './src/main/updateFeed';

// The GUI update feed is opt-in at build time (see src/main/updateFeed.ts).
// Without DARKBLOOM_DESKTOP_UPDATE_URL, `publish: null` embeds no app-update.yml
// and stops electron-builder from inferring a GitHub feed from GH_TOKEN.
// A release build (DARKBLOOM_DESKTOP_RELEASE=1, set by release-desktop.yml) must embed an update
// feed: the feed is fixed at build time, so a release without one could never update itself. It
// refuses to build otherwise.
// A release build is never signed or notarized here. release-desktop.yml builds the unsigned app
// in a job that holds no key, signs and notarizes it in another job with
// scripts/sign-desktop-app.py, and packages the signed app with `--prepackaged`.
// Every signer uses these entitlements: that script, and electron-builder for a development or
// preview build.
export const entitlements = 'resources/entitlements.mac.plist';

export function desktopBuildConfig(env: NodeJS.ProcessEnv): Configuration {
  const team = env.DARKBLOOM_PREVIEW_TEAM_ID || '';
  const runtime = env.DARKBLOOM_PREVIEW_RUNTIME;
  if ((team && !/^[A-Z0-9]{10}$/.test(team)) || !!team !== !!runtime)
    throw new Error(
      'Local previews require DARKBLOOM_PREVIEW_RUNTIME and a valid DARKBLOOM_PREVIEW_TEAM_ID',
    );
  const release = env.DARKBLOOM_DESKTOP_RELEASE === '1';
  if (release) {
    if (team) throw new Error('A release build cannot also be a local preview');
    if (!publishConfig(env[updateFeedEnv]))
      throw new Error(`A release build needs ${updateFeedEnv} so installs can update themselves`);
  }
  return {
    appId: team ? 'io.darkbloom.desktop.preview' : 'io.darkbloom.desktop',
    productName: team ? 'Darkbloom Preview' : 'Darkbloom',
    ...(team ? { forceCodeSigning: true, dmg: { sign: true } } : {}),
    directories: { output: 'release' },
    files: ['dist/**/*', 'package.json'],
    extraResources: [
      { from: 'resources', to: 'bootstrap', filter: ['install-runtime.sh'] },
      ...(runtime
        ? [{ from: runtime, to: 'preview-runtime', filter: ['darkbloom', '*.bundle/**/*'] }]
        : []),
    ],
    mac: {
      category: 'public.app-category.utilities',
      target: [
        { target: 'dmg', arch: ['arm64'] },
        { target: 'zip', arch: ['arm64'] },
      ],
      hardenedRuntime: true,
      entitlements,
      entitlementsInherit: entitlements,
      minimumSystemVersion: '14.0',
      extendInfo: { LSUIElement: true },
      icon: 'resources/icon.icns',
      // Stable names for the GitHub release assets, e.g. Darkbloom-0.1.0-arm64.dmg.
      artifactName: '${productName}-${version}-${arch}.${ext}',
      notarize: false,
      // No identity: a release build stays unsigned whatever certificates the machine has.
      ...(release ? { identity: null } : {}),
      ...(team
        ? {
            signIgnore: ['preview-runtime/'],
            // electron-builder otherwise passes the certificate's display name
            // with validation disabled. Resolve the exact fingerprint instead;
            // renewed certificates can legitimately have identical names.
            sign: async (options) => {
              await signAsync({
                ...options,
                identity: env.CSC_NAME || options.identity,
                identityValidation: true,
              });
            },
          }
        : {}),
    },
    publish: team ? null : publishConfig(env[updateFeedEnv]),
  };
}

export default () => desktopBuildConfig(process.env);
