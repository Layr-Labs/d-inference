import type { CreatedKey } from "@/lib/api";
import { revokeLegacyApiKey } from "@/lib/api/keys";
import { API_KEY_STORAGE, CONSOLE_KEY_ID_STORAGE } from "./constants";

// Auto-provision writes the secret but not the console key id. A key the user
// just created should replace that untracked mint so chat does not keep an
// unrestricted "Untitled key" after they made a My Machine only key.
//
// writeUntrackedConsoleApiKey / clearConsoleApiKey must drop leftover ids:
// secret + stale id is treated as an explicit console-key choice.
export function adoptCreatedKeyIfUntracked(
  created: CreatedKey,
  token: string,
  point: (created: CreatedKey) => void,
): boolean {
  if (typeof window === "undefined") return false;
  const previousSecret = localStorage.getItem(API_KEY_STORAGE);
  const previousId = localStorage.getItem(CONSOLE_KEY_ID_STORAGE);
  if (previousSecret && previousId) return false;
  point(created);
  if (previousSecret && previousSecret !== created.key) {
    revokeLegacyApiKey(token, previousSecret);
  }
  return true;
}
