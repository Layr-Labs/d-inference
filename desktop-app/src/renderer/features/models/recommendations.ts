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

export interface ChipEarning {
  median: bigint;
  mean: bigint;
}

const isAmount = (value: unknown) => typeof value === 'string' && /^\d+$/.test(value);

// What one Mac with this chip earned per day from each model over the last 24 hours, across the
// network's Macs of that chip serving the model. Null when the network has no class for this chip
// or the data is missing, stale or malformed.
export function chipEarnings(
  network: NetworkData | undefined,
  chip: string | undefined,
): ReadonlyMap<string, ChipEarning> | null {
  const data = network?.model_earnings;
  if (!chip || !networkEarnings(network) || !data || data.by_chip_window !== '24h') return null;
  const earnings = new Map<string, ChipEarning>();
  for (const row of data.models) {
    if (row.by_chip === undefined) continue;
    if (!Array.isArray(row.by_chip)) return null;
    for (const entry of row.by_chip) {
      if (
        typeof entry?.chip !== 'string' ||
        !Number.isSafeInteger(entry.machines) ||
        entry.machines < 1 ||
        !isAmount(entry.median_micro_usd_per_machine_day) ||
        !isAmount(entry.mean_micro_usd_per_machine_day)
      )
        return null;
      if (entry.chip === chip)
        earnings.set(row.id, {
          median: BigInt(entry.median_micro_usd_per_machine_day),
          mean: BigInt(entry.mean_micro_usd_per_machine_day),
        });
    }
  }
  return earnings.size ? earnings : null;
}

// Per-chip earnings rank the recommendations only when they recommend a model this Mac can
// serve; otherwise the ranking and its copy fall back to network totals together.
export function chipRanking(
  models: NativeModel[],
  perChip: ReadonlyMap<string, ChipEarning> | null,
): ReadonlyMap<string, ChipEarning> | null {
  return perChip && recommendedModels(models, null, perChip).length ? perChip : null;
}

// Prefer what Macs like this one earn: the network total favors models that many fast Macs serve,
// which can pay a slower Mac nothing.
export function recommendedModels(
  models: NativeModel[],
  amounts: ReadonlyMap<string, bigint> | null,
  perChip: ReadonlyMap<string, ChipEarning> | null = null,
) {
  if (perChip)
    return models
      .filter((model) => model.eligible && (perChip.get(model.id)?.mean ?? 0n) > 0n)
      .sort((a, b) => {
        const left = perChip.get(a.id)!,
          right = perChip.get(b.id)!;
        if (left.median !== right.median) return left.median > right.median ? -1 : 1;
        if (left.mean !== right.mean) return left.mean > right.mean ? -1 : 1;
        return a.display_name.localeCompare(b.display_name);
      })
      .slice(0, 3);
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
