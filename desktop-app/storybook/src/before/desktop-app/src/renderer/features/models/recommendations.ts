import type { NativeModel, NetworkData, Snapshot } from '../../../shared/contracts';
import type { AutopilotAction } from '../../../shared/autopilot';

export function networkEarnings(network?: NetworkData): ReadonlyMap<string, bigint> | null {
  const data = network?.model_earnings;
  const at = data ? Date.parse(data.as_of) : NaN;
  if (
    !data ||
    network?.error ||
    data.window !== '7d' ||
    !Number.isFinite(at) ||
    Date.now() - at > 5 * 60_000 ||
    !Array.isArray(data.models)
  )
    return null;
  const amounts = new Map<string, bigint>();
  for (const row of data.models) {
    if (
      typeof row.id !== 'string' ||
      !row.id ||
      typeof row.earnings_micro_usd !== 'string' ||
      !/^\d+$/.test(row.earnings_micro_usd) ||
      amounts.has(row.id)
    )
      return null;
    amounts.set(row.id, BigInt(row.earnings_micro_usd));
  }
  return amounts;
}

export function recommendedModels(
  models: NativeModel[],
  amounts: ReadonlyMap<string, bigint> | null,
) {
  if (!amounts) return [];
  return rankNetworkModels(
    models.filter((model) => model.eligible && (amounts.get(model.id) ?? 0n) > 0n),
    amounts,
  ).slice(0, 3);
}

export function rankNetworkModels(
  models: NativeModel[],
  amounts: ReadonlyMap<string, bigint> | null,
) {
  if (!amounts) return [...models].sort((a, b) => a.display_name.localeCompare(b.display_name));
  return [...models].sort((a, b) => {
    const left = amounts.get(a.id) ?? 0n,
      right = amounts.get(b.id) ?? 0n;
    return left > right ? -1 : left < right ? 1 : a.display_name.localeCompare(b.display_name);
  });
}

export function recommendedStart(
  snapshot: Snapshot,
  selected: NativeModel[],
  pinned: string[] = [],
): AutopilotAction {
  const ids = selected.map((model) => model.id);
  const startup = pinned.length ? pinned : ids.slice(0, 1);
  return {
    action: 'autopilot',
    models: startup,
    pinned,
    downloads: selected.filter((model) => !model.downloaded).map((model) => model.id),
    endpoint: !!snapshot.endpoint,
  };
}
