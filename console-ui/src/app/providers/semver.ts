interface ParsedSemver {
  major: number;
  minor: number;
  patch: number;
  prerelease: string[];
}

function parseSemver(value: string): ParsedSemver | null {
  const [withoutBuild] = value.replace(/^v/, "").split("+", 1);
  const [core, prerelease] = withoutBuild.split("-", 2);
  const parts = core.split(".");
  if (parts.length !== 3) return null;
  const [major, minor, patch] = parts.map(Number);
  if (![major, minor, patch].every(Number.isInteger)) return null;
  return { major, minor, patch, prerelease: prerelease?.split(".") ?? [] };
}

function comparePrereleaseIdentifier(left: string, right: string): number {
  const leftNumber = /^\d+$/.test(left) ? Number(left) : null;
  const rightNumber = /^\d+$/.test(right) ? Number(right) : null;
  if (leftNumber !== null && rightNumber !== null) return leftNumber - rightNumber;
  if (leftNumber !== null) return -1;
  if (rightNumber !== null) return 1;
  return left.localeCompare(right);
}

function prereleaseIsLess(left: string[], right: string[]): boolean {
  if (left.length === 0) return false;
  if (right.length === 0) return true;
  for (const [index, leftPart] of left.entries()) {
    const rightPart = right.at(index);
    if (rightPart === undefined) return false;
    const comparison = comparePrereleaseIdentifier(leftPart, rightPart);
    if (comparison !== 0) return comparison < 0;
  }
  return left.length < right.length;
}

export function semverLess(leftVersion: string, rightVersion: string): boolean {
  if (!leftVersion) return Boolean(rightVersion);
  if (!rightVersion) return false;
  const left = parseSemver(leftVersion);
  const right = parseSemver(rightVersion);
  if (!left || !right) return false;
  if (left.major !== right.major) return left.major < right.major;
  if (left.minor !== right.minor) return left.minor < right.minor;
  if (left.patch !== right.patch) return left.patch < right.patch;
  return prereleaseIsLess(left.prerelease, right.prerelease);
}
