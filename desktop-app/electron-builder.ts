import type { Configuration } from 'electron-builder';
import { signAsync } from '@electron/osx-sign';
import { publishConfig, updateFeedEnv } from './src/main/updateFeed';

// The GUI update feed is opt-in at build time (see src/main/updateFeed.ts).
// Without DARKBLOOM_DESKTOP_UPDATE_URL, `publish: null` embeds no app-update.yml
// and stops electron-builder from inferring a GitHub feed from GH_TOKEN.
// A release build (DARKBLOOM_DESKTOP_RELEASE=1, set by release-desktop.yml) must be signed and
// notarized with the Developer ID team that also signs the CLI, and must embed an update feed:
// the feed is fixed at build time, so a release without one could never update itself.
// It refuses to build otherwise.
export const releaseTeam = 'SLDQ2GJ6TL';
const notarizationEnv = ['APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID'] as const;

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
    const missing = notarizationEnv.filter((name) => !env[name]);
    if (missing.length)
      throw new Error(`A release build needs notarization credentials: ${missing.join(', ')}`);
    if (env.APPLE_TEAM_ID !== releaseTeam)
      throw new Error(`A release build must be notarized for team ${releaseTeam}`);
    if (!publishConfig(env[updateFeedEnv]))
      throw new Error(`A release build needs ${updateFeedEnv} so installs can update themselves`);
  }
  return {
    appId: team ? 'io.darkbloom.desktop.preview' : 'io.darkbloom.desktop',
    productName: team ? 'Darkbloom Preview' : 'Darkbloom',
    ...(team ? { forceCodeSigning: true, dmg: { sign: true } } : {}),
    // Release builds fail instead of falling back to an unsigned app.
    ...(release ? { forceCodeSigning: true } : {}),
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
      minimumSystemVersion: '14.0',
      extendInfo: { LSUIElement: true },
      icon: 'resources/icon.icns',
      // Stable names for the GitHub release assets, e.g. Darkbloom-0.1.0-arm64.dmg.
      artifactName: '${productName}-${version}-${arch}.${ext}',
      // electron-builder notarizes and staples the app with APPLE_ID,
      // APPLE_APP_SPECIFIC_PASSWORD and APPLE_TEAM_ID; the workflow then notarizes the DMG.
      notarize: release,
      ...(team ? { signIgnore: ['preview-runtime/'] } : {}),
      ...(team || release
        ? {
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
