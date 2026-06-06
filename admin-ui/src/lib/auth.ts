// HTTP Basic Auth check used by the Next proxy (runs on the Edge runtime — no
// Node-only APIs). Compares SHA-256 digests in constant time and evaluates BOTH
// the username and password without short-circuiting, so neither the secret
// length nor which half was wrong leaks via timing.
// Internal tool: a single shared admin credential is enough; tighten to SSO/IAP
// when this moves behind a real gateway.

// Compare two strings in constant time by comparing their fixed-length SHA-256
// digests (equal length regardless of input, so no length leak). crypto.subtle
// is available on the Edge runtime.
async function digestEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const x = new Uint8Array(ha);
  const y = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

export async function checkBasicAuth(header: string | null): Promise<boolean> {
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
  // Evaluate both halves before combining — do NOT short-circuit with `&&`,
  // which would skip the password compare (and leak username correctness) when
  // the username is wrong.
  const [userOk, passOk] = await Promise.all([
    digestEqual(gotUser, user),
    digestEqual(gotPass, pass),
  ]);
  return userOk && passOk;
}
