import type { App, Settings } from 'electron';
import path from 'node:path';
import { mkdir, readFile, writeFile } from 'node:fs/promises';

// Explicit opt-in for launching without a window (scripts, development).
export const hiddenArgument = '--hidden';

// Login-item `args` are Windows-only in Electron (`Settings.args` is
// `@platform win32`), so macOS cannot pass `--hidden` to a login launch. macOS
// instead reports the launch through `LoginItemSettings.wasOpenedAtLogin`.
export function shouldStartHidden(argv: readonly string[], wasOpenedAtLogin: boolean) {
  return wasOpenedAtLogin || argv.includes(hiddenArgument);
}

export function loginItemSettings(): Settings {
  return { openAtLogin: true };
}

// Read once at startup: whether this launch came from the macOS login item.
export function launchedHidden(app: App, argv: readonly string[] = process.argv) {
  return shouldStartHidden(argv, app.isPackaged && app.getLoginItemSettings().wasOpenedAtLogin);
}

// First packaged launch registers the app as a login item exactly once; later
// changes the user makes in System Settings are never overwritten.
export async function initializeLoginItem(app: App) {
  const preferencePath = path.join(app.getPath('userData'), 'login-initialized.json');
  try {
    await readFile(preferencePath);
  } catch {
    app.setLoginItemSettings(loginItemSettings());
    await mkdir(app.getPath('userData'), { recursive: true });
    await writeFile(preferencePath, '{"initialized":true}', { mode: 0o600 });
  }
}
