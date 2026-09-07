export const REFERRAL_STORAGE_KEY = "darkbloom_referral_v1";

export function normalizeReferral(value: string | null): string | null {
  // Existing codes accepted Unicode letters/digits and a UTF-8 byte limit.
  // Match Go's simple uppercase mapping (e.g. ß stays ß rather than expanding).
  const code = Array.from(value?.trim() ?? "", (letter) => {
    const upper = letter.toUpperCase();
    return Array.from(upper).length === 1 ? upper : letter;
  }).join("");
  const bytes = new TextEncoder().encode(code).length;
  if (bytes < 3 || bytes > 20 || code.startsWith("-") || code.endsWith("-")) return null;
  return /^[\p{L}\p{Nd}-]+$/u.test(code) ? code : null;
}

export function normalizeRegistrationCode(value: string): string | null {
  const code = value.trim();
  return /^[A-Za-z0-9][A-Za-z0-9-]{1,18}[A-Za-z0-9]$/.test(code) ? code.toUpperCase() : null;
}

export function readReferral(): string | null {
  try { return normalizeReferral(localStorage.getItem(REFERRAL_STORAGE_KEY)); }
  catch { return null; }
}

// Preserve the first valid link through navigation and the login round trip.
// Invitation codes are a separate system and never enter this storage key.
export function captureReferral(search: string): string | null {
  const existing = readReferral();
  if (existing) return existing;
  const code = normalizeReferral(new URLSearchParams(search).get("ref"));
  if (code) {
    try { localStorage.setItem(REFERRAL_STORAGE_KEY, code); }
    catch { /* The current page can still apply it when storage is disabled. */ }
  }
  return code;
}

export function clearReferral(code: string): void {
  try {
    if (readReferral() === code) localStorage.removeItem(REFERRAL_STORAGE_KEY);
  } catch { /* Storage can be disabled; attribution still works in memory. */ }
}
