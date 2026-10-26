// Darkbloom accepts new providers only on macOS 27 or later. Macs that already run the
// Darkbloom CLI on an earlier release keep serving (the coordinator decides whether they stay
// authorized) and are prompted to update.
export const minimumMacOS = 27;

// Facts about this Mac that only the main process can read.
export interface SystemInfo {
  // macOS's product version, e.g. "27.0" or "26.5.1"; empty when it couldn't be read.
  macosVersion: string;
}

// The major release of a macOS product version, or undefined when it can't be read.
export function macosMajor(version: string | undefined): number | undefined {
  const match = /^(\d+)(?:\.\d+){0,2}$/.exec(version?.trim() ?? '');
  return match ? Number(match[1]) : undefined;
}

// Whether this Mac's macOS can join Darkbloom as a new provider. An unknown version is
// never guessed to be too old.
export function supportsNewProviders(version: string | undefined): boolean {
  const major = macosMajor(version);
  return major === undefined || major >= minimumMacOS;
}
