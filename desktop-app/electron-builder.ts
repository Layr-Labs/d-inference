import type { Configuration } from 'electron-builder';
import { signAsync } from '@electron/osx-sign';
import { publishConfig, updateFeedEnv } from './src/main/updateFeed';

// The GUI update feed is opt-in at build time (see src/main/updateFeed.ts).
// Without DARKBLOOM_DESKTOP_UPDATE_URL, `publish: null` embeds no app-update.yml
// and stops electron-builder from inferring a GitHub feed from GH_TOKEN.
export function desktopBuildConfig(env: NodeJS.ProcessEnv): Configuration {
  const team = env.DARKBLOOM_PREVIEW_TEAM_ID || '';
  const runtime = env.DARKBLOOM_PREVIEW_RUNTIME;
  if ((team && !/^[A-Z0-9]{10}$/.test(team)) || !!team !== !!runtime)
    throw new Error(
      'Local previews require DARKBLOOM_PREVIEW_RUNTIME and a valid DARKBLOOM_PREVIEW_TEAM_ID',
    );
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
      minimumSystemVersion: '14.0',
      extendInfo: { LSUIElement: true },
      icon: 'resources/icon.icns',
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
