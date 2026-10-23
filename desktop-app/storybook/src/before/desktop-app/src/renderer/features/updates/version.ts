import type { ReleaseData, ReleaseHistory, Snapshot } from '../../../shared/contracts';

// Presentation only. The native updater and coordinator retain update authority.
export function compareVersions(a?: string, b?: string): number | undefined {
  const parse = (value?: string) => {
    const match = value?.match(
      /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/,
    );
    return match ? { core: match.slice(1, 4).map(BigInt), pre: match[4]?.split('.') } : undefined;
  };
  const left = parse(a),
    right = parse(b);
  if (!left || !right) return undefined;
  for (let i = 0; i < 3; i++) {
    if (left.core[i] !== right.core[i]) return left.core[i] < right.core[i] ? -1 : 1;
  }
  if (!left.pre && !right.pre) return 0;
  if (!left.pre) return 1;
  if (!right.pre) return -1;
  for (let i = 0; i < Math.max(left.pre.length, right.pre.length); i++) {
    const x = left.pre[i],
      y = right.pre[i];
    if (x === y) continue;
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const nx = /^\d+$/.test(x),
      ny = /^\d+$/.test(y);
    if (nx && ny) return BigInt(x) < BigInt(y) ? -1 : 1;
    if (nx !== ny) return nx ? -1 : 1;
    return x < y ? -1 : 1;
  }
  return 0;
}

export function releaseStatus(
  installed: string,
  latest?: string,
  minimum?: string,
  retired = false,
) {
  if (minimum && compareVersions(installed, minimum) === -1) return 'required';
  if (retired) return 'retired';
  if (compareVersions(installed, latest) === -1) return 'available';
  if (compareVersions(installed, latest) !== undefined) return 'current';
  return 'unknown';
}

// A serving provider reports its own version; otherwise the CLI's applies.
// The latest published release and the coordinator's minimum, each withheld while its resource
// reports an error.
export const publishedVersions = (sources: {
  release?: ReleaseData;
  releaseHistory?: ReleaseHistory;
  cloud?: { minimum_provider_version?: string };
}) => ({
  latest: sources.release?.error ? undefined : sources.release?.version,
  minimum:
    sources.cloud?.minimum_provider_version ??
    (sources.releaseHistory?.error ? undefined : sources.releaseHistory?.minimum_provider_version),
});

export const runtimeVersion = (state: Snapshot) =>
  ['running', 'draining'].includes(state.state)
    ? state.machine.version || state.version
    : state.version;

export const updateAvailable = (installed: string, latest?: string, minimum?: string) =>
  !!latest &&
  compareVersions(latest, installed) === 1 &&
  (!minimum || (compareVersions(latest, minimum) ?? -1) >= 0);

export function parseReleaseHistory(value: unknown): ReleaseHistory {
  if (!value || typeof value !== 'object') throw new Error('Missing release history');
  const data = value as Record<string, unknown>;
  if (typeof data.minimum_provider_version !== 'string' || !Array.isArray(data.history))
    throw new Error('Missing support policy');
  const history = data.history.map((entry: unknown) => {
    if (!entry || typeof entry !== 'object') throw new Error('Invalid release');
    const row = entry as Record<string, unknown>;
    if (
      typeof row.version !== 'string' ||
      typeof row.published_at !== 'string' ||
      typeof row.notes !== 'string' ||
      typeof row.active !== 'boolean'
    )
      throw new Error('Invalid release');
    return {
      version: row.version,
      published_at: row.published_at,
      notes: row.notes,
      active: row.active,
    };
  });
  return {
    minimum_provider_version: data.minimum_provider_version,
    history,
    observed_at: typeof data.observed_at === 'string' ? data.observed_at : undefined,
  };
}
