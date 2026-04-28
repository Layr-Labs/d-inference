/**
 * One-time migration of localStorage keys from darkbloom to darkbloom.
 * Called at module scope from ThemeProvider (outermost client component) so it
 * runs before any component reads localStorage.
 */

const KEY_MAP: [string, string][] = [
  ["darkbloom_api_key", "darkbloom_api_key"],
  ["darkbloom_coordinator_url", "darkbloom_coordinator_url"],
  ["darkbloom-store", "darkbloom-store"],
  ["darkbloom-theme", "darkbloom-theme"],
  ["darkbloom-verification-mode", "darkbloom-verification-mode"],
  ["darkbloom_invite_dismissed", "darkbloom_invite_dismissed"],
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
