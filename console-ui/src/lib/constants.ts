// Single source of truth for localStorage keys shared across features.
//
// Before this module these strings were redefined in api-keys/constants.ts,
// lib/api.ts, api-console/page.tsx, hooks/useAuth.ts, settings, earnings, etc.
// Re-declaring them risked drift (a typo in one place silently breaks auth).
// Module-private keys that only one file ever touches (encryption flag, the
// persisted store name, theme) stay co-located with their owner.

export const STORAGE_KEYS = {
  /** Active inference API key used by the console's own chat/test calls. */
  apiKey: "darkbloom_api_key",
  /** Pre-rebrand inference key; migrated forward then removed. */
  legacyApiKey: "eigeninference_api_key",
  /** Which managed key is currently the console's active key. */
  consoleKeyId: "darkbloom_console_key_id",
  /** User-selected coordinator base URL override (client side only). */
  coordinatorUrl: "darkbloom_coordinator_url",
  /** Verification panel display mode ("normal" | "technical"). */
  verificationMode: "darkbloom-verification-mode",
} as const;

export type StorageKey = (typeof STORAGE_KEYS)[keyof typeof STORAGE_KEYS];
