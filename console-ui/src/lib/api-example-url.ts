import { STORAGE_KEYS } from "./constants";
import { PUBLIC_COORDINATOR_URL } from "./coordinator-url";

/** Example code preference only; never used for console routing or encryption. */
export function apiExampleUrl(): string {
  if (typeof window === "undefined") return PUBLIC_COORDINATOR_URL;
  return window.localStorage.getItem(STORAGE_KEYS.apiExampleUrl) || PUBLIC_COORDINATOR_URL;
}
