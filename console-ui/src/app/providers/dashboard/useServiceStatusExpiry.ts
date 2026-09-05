import { useEffect, useState } from "react";
import type { MyProvider } from "../types";
import { freshServiceStatus } from "./serviceStatus";

// Expire observations even if the next network poll hangs. One timer serves
// the whole fleet; expired records never schedule an immediate retry loop.
export function useServiceStatusExpiry(providers: MyProvider[]): number {
  const [version, setVersion] = useState(0);
  useEffect(() => {
    const now = Date.now();
    let next = Infinity;
    for (const provider of providers) {
      const status = freshServiceStatus(provider, now);
      if (status) next = Math.min(next, Date.parse(status.expires_at));
    }
    if (!Number.isFinite(next)) return;
    const timer = setTimeout(() => setVersion(value => value + 1), Math.max(0, next - Date.now()) + 1);
    return () => clearTimeout(timer);
  }, [providers, version]);
  return version;
}
