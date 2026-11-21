import type { GUIUpdate } from '../shared/contracts';

// The desktop app's own update feed is an explicit build-time choice. It must
// never default to the repository's GitHub releases: those are provider
// runtime releases (no `latest-mac.yml`), so electron-updater would fail every
// check. electron-builder embeds the feed as `Resources/app-update.yml`, and
// the packaged app keys off that file, so build and runtime cannot drift.
export const updateFeedEnv = 'DARKBLOOM_DESKTOP_UPDATE_URL';
export const updateConfigFile = 'app-update.yml';

export function publishConfig(value: string | undefined) {
  const url = value?.trim();
  if (!url) return null;
  if (!URL.canParse(url) || new URL(url).protocol !== 'https:')
    throw new Error(`${updateFeedEnv} must be an https URL`);
  return { provider: 'generic' as const, url };
}

const genericProvider = /^provider:\s*(['"]?)generic\1\s*$/m;
const httpsURL = /^url:\s*['"]?https:\/\/\S+/m;
// Only a generic https feed written by our build config counts as configured.
export function feedConfigured(appUpdateYml: string | undefined) {
  return !!appUpdateYml && genericProvider.test(appUpdateYml) && httpsURL.test(appUpdateYml);
}

export function updateChecksEnabled(build: {
  packaged: boolean;
  smokeTest: boolean;
  config: string | undefined;
}) {
  return build.packaged && !build.smokeTest && feedConfigured(build.config);
}

export const unconfiguredUpdate: GUIUpdate = {
  state: 'unconfigured',
  message: 'Desktop app updates are not configured for this build.',
};

export function initialUpdateState(enabled: boolean): GUIUpdate {
  return enabled ? { state: 'idle' } : unconfiguredUpdate;
}

export type UpdaterEvent =
  | { type: 'checking' }
  | { type: 'available'; version: string }
  | { type: 'not-available' }
  | { type: 'downloaded'; version: string }
  | { type: 'error'; message: string };

export function nextUpdateState(event: UpdaterEvent): GUIUpdate {
  switch (event.type) {
    case 'checking':
      return { state: 'checking' };
    case 'available':
      return { state: 'downloading', version: event.version };
    case 'not-available':
      return { state: 'idle' };
    case 'downloaded':
      return { state: 'ready', version: event.version };
    case 'error':
      return { state: 'error', message: event.message };
  }
}
