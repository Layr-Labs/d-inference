const CONFIGURED_RELEASE_HASHES = process.env.NEXT_PUBLIC_DARKBLOOM_PRIVATE_V2_RELEASE_HASHES;

interface ParsedReleaseAllowlist {
  hashes: ReadonlySet<string>;
  error: string | null;
}

export function parsePrivateV2ReleaseAllowlist(value: string | undefined): ParsedReleaseAllowlist {
  if (!value) {
    return {
      hashes: new Set(),
      error: "Private v2 release allowlist is not configured",
    };
  }
  const entries = value.split(",");
  const hashes = new Set<string>();
  for (const entry of entries) {
    if (!/^[0-9a-f]{64}$/u.test(entry)) {
      return {
        hashes: new Set(),
        error: "Private v2 release allowlist contains an invalid hash",
      };
    }
    if (hashes.has(entry)) {
      return {
        hashes: new Set(),
        error: "Private v2 release allowlist contains a duplicate hash",
      };
    }
    hashes.add(entry);
  }
  return { hashes, error: null };
}

const releaseAllowlist = parsePrivateV2ReleaseAllowlist(CONFIGURED_RELEASE_HASHES);

function assertPinnedRelease(
  releaseBinaryHash: string,
  allowlist: ParsedReleaseAllowlist,
): void {
  if (!/^[0-9a-f]{64}$/u.test(releaseBinaryHash)) {
    throw new Error("Certified provider release hash is not canonical lowercase SHA-256");
  }
  if (allowlist.error) throw new Error(allowlist.error);
  if (!allowlist.hashes.has(releaseBinaryHash)) {
    throw new Error("Certified provider release is not pinned by this console build");
  }
}

/** Explicit configuration seam for release-policy tests. */
export function validatePrivateV2ReleasePin(
  releaseBinaryHash: string,
  configuredHashes: string | undefined,
): void {
  assertPinnedRelease(releaseBinaryHash, parsePrivateV2ReleaseAllowlist(configuredHashes));
}

export function requirePinnedPrivateV2Release(releaseBinaryHash: string): void {
  assertPinnedRelease(releaseBinaryHash, releaseAllowlist);
}
