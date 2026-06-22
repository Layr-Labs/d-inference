// Client-side HTTP helpers for talking to the Next.js /api/* proxy routes.
//
// All browser requests go through same-origin /api/* (which inject the upstream
// auth and resolve the coordinator URL server-side). These helpers centralize
// the header construction and error-unwrapping that lib/api.ts previously
// repeated ~20 times with three inconsistent error styles (proposal F1).

import { STORAGE_KEYS } from "@/lib/constants";

/** The active inference API key from localStorage ("" on the server). */
export function getApiKey(): string {
  if (typeof window === "undefined") return "";
  return localStorage.getItem(STORAGE_KEYS.apiKey) || "";
}

/** Headers for inference/proxy calls: JSON + the x-api-key (when present). */
export function proxyHeaders(extra?: Record<string, string>): Record<string, string> {
  const apiKey = getApiKey();
  return {
    "Content-Type": "application/json",
    ...(apiKey ? { "x-api-key": apiKey } : {}),
    ...extra,
  };
}

/** Headers for account-management calls authenticated with a Privy token. */
export function managementHeaders(token: string): Record<string, string> {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

/**
 * Build an Error from a failed proxy response, unwrapping the coordinator's
 * structured error shapes ({error:{message}}, {error:"..."}, {message}) and
 * falling back to "<fallback> (<status>)".
 */
export async function apiError(res: Response, fallback: string): Promise<Error> {
  const data = await res.json().catch(() => null);
  if (data && typeof data === "object") {
    const err = (data as Record<string, unknown>).error;
    if (typeof err === "string" && err) return new Error(err);
    if (err && typeof err === "object") {
      const message = (err as Record<string, unknown>).message;
      if (typeof message === "string" && message) return new Error(message);
    }
    const message = (data as Record<string, unknown>).message;
    if (typeof message === "string" && message) return new Error(message);
  }
  return new Error(`${fallback} (${res.status})`);
}

/** Parse JSON on success, or throw an unwrapped {@link apiError} on failure. */
export async function jsonOrThrow<T>(res: Response, fallback: string): Promise<T> {
  if (!res.ok) throw await apiError(res, fallback);
  return res.json() as Promise<T>;
}
