import { STORAGE_KEYS } from "./storage-keys";

function onBrowser(fn: () => void): void {
  if (typeof window === "undefined") return;
  fn();
}

/** Drop the console inference secret and its tracked key id together. */
export function clearConsoleApiKey(): void {
  onBrowser(() => {
    localStorage.removeItem(STORAGE_KEYS.apiKey);
    localStorage.removeItem(STORAGE_KEYS.legacyApiKey);
    localStorage.removeItem(STORAGE_KEYS.consoleKeyId);
  });
}

/**
 * Persist an auto-provisioned secret without treating it as a tracked console
 * key. A leftover `darkbloom_console_key_id` from a previous key must not stay
 * beside this mint — adoptCreatedKeyIfUntracked would then refuse to replace
 * the untitled secret with a key the user just created.
 */
export function writeUntrackedConsoleApiKey(secret: string): void {
  onBrowser(() => {
    localStorage.setItem(STORAGE_KEYS.apiKey, secret);
    localStorage.removeItem(STORAGE_KEYS.consoleKeyId);
  });
}
