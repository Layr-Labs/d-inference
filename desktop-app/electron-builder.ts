import type { Configuration } from 'electron-builder';
import { publishConfig, updateFeedEnv } from './src/main/updateFeed';

// The GUI update feed is opt-in at build time (see src/main/updateFeed.ts).
// Without DARKBLOOM_DESKTOP_UPDATE_URL, `publish: null` embeds no app-update.yml
// and stops electron-builder from inferring a GitHub feed from GH_TOKEN.
export function desktopBuildConfig(env: NodeJS.ProcessEnv): Configuration {
  return {
    appId: 'io.darkbloom.desktop',
    productName: 'Darkbloom',
    directories: { output: 'release' },
    files: ['dist/**/*', 'package.json'],
    extraResources: [{ from: 'resources', to: 'bootstrap', filter: ['install-runtime.sh'] }],
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
    },
    publish: publishConfig(env[updateFeedEnv]),
  };
}

export default () => desktopBuildConfig(process.env);
