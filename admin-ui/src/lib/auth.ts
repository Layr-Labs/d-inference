// HTTP Basic Auth check used by edge middleware (no Node-only APIs).
// Constant-time-ish comparison.
// Internal tool: a single shared admin credential is enough; tighten to SSO/IAP
// when this moves behind a real gateway.

function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function checkBasicAuth(header: string | null): boolean {
  const user = process.env.ADMIN_BASIC_USER;
  const pass = process.env.ADMIN_BASIC_PASS;
  // If unset, fail closed (deny) rather than open.
  if (!user || !pass) return false;
  if (!header || !header.startsWith("Basic ")) return false;
  let decoded: string;
  try {
    decoded = atob(header.slice("Basic ".length).trim());
  } catch {
    return false;
  }
  const idx = decoded.indexOf(":");
  if (idx < 0) return false;
  const gotUser = decoded.slice(0, idx);
  const gotPass = decoded.slice(idx + 1);
  return safeEqual(gotUser, user) && safeEqual(gotPass, pass);
}
