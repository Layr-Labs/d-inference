/**
 * One-time migration of localStorage keys from eigeninference to darkbloom.
 * Called by ThemeProvider's state initializer so it runs before descendants
 * read localStorage.
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
  try {
    for (const [oldKey, newKey] of KEY_MAP) {
      const oldVal = localStorage.getItem(oldKey);
      if (oldVal !== null && localStorage.getItem(newKey) === null) {
        localStorage.setItem(newKey, oldVal);
        localStorage.removeItem(oldKey);
      }
    }
    migrated = true;
  } catch {
    // Storage is optional. Sandboxed/private contexts may deny all access.
  }
}
