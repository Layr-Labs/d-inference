import type { MyProvider } from "./types";

export function reportedMacOSMajor(provider: Pick<MyProvider, "os_version">): number | null {
  const version = provider.os_version?.trim();
  if (!version || !/^\d{1,2}(?:\.\d{1,3}){0,2}$/.test(version)) return null;
  const major = Number(version.split(".")[0]);
  return major > 0 ? major : null;
}

export function needsMacOSUpgrade(provider: Pick<MyProvider, "os_version">): boolean {
  const major = reportedMacOSMajor(provider);
  return major !== null && major < 27;
}
