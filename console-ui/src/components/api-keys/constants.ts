import type { KeyResetWindow } from "@/lib/api";

// localStorage keys. The console uses a single "active" key for its own chat /
// test calls (API_KEY_STORAGE) and tracks which managed key that is so the
// "Console key" badge and rotate/delete bookkeeping stay in sync.
export const API_KEY_STORAGE = "darkbloom_api_key";
export const CONSOLE_KEY_ID_STORAGE = "darkbloom_console_key_id";

// Shared Tailwind class strings for form controls.
export const INPUT_CLS =
  "w-full bg-bg-primary border border-border-dim rounded-lg px-3 py-2 text-sm text-text-primary outline-none focus:border-coral transition-colors placeholder:text-text-tertiary/60";
export const LABEL_CLS =
  "block text-xs font-mono text-text-tertiary uppercase tracking-wider mb-1.5";

// User-facing copy.
export const SECRET_WARNING =
  "Copy this secret now and store it somewhere safe. For your security, you won't be able to view it again.";
export const SHARED_BALANCE_NOTE =
  "All keys draw from your shared account balance. A key's spend cap is a sub-limit on that balance, not extra funds.";
export const CONSOLE_KEY_NOTE =
  "This console uses one active key (saved in this browser) for its own chat and test calls. It's provisioned automatically; you can also point it at a new key below.";

export const RESET_OPTIONS: { value: KeyResetWindow; label: string }[] = [
  { value: "none", label: "Lifetime (no reset)" },
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "monthly", label: "Monthly" },
];
