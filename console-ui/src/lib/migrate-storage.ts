/**
 * One-time migration of localStorage keys from eigeninference to darkbloom.
 * Called at module scope from ThemeProvider (outermost client component) so it
 * runs before any component reads localStorage.
 */

const KEY_MAP: [string, string][] = [
  ["eigeninference_api_key", "darkbloom_api_key"],
  ["eigeninference_coordinator_url", "darkbloom_coordinator_url"],
  ["eigeninference-store", "darkbloom-store"],
  ["eigeninference-theme", "darkbloom-theme"],
  ["eigeninference-verification-mode", "darkbloom-verification-mode"],
  ["eigeninference_invite_dismissed", "darkbloom_invite_dismissed"],
];

let migrated = false;

export function migrateStorage() {
  if (migrated || typeof window === "undefined") return;
  migrated = true;

  for (const [oldKey, newKey] of KEY_MAP) {
    const oldVal = localStorage.getItem(oldKey);
    if (oldVal !== null && localStorage.getItem(newKey) === null) {
      localStorage.setItem(newKey, oldVal);
      localStorage.removeItem(oldKey);
    }
  }
}
