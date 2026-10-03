// Rounds half up to whole cents, or finer when `digits` exceeds 2; `digits = 0` drops the cents.
export function money(micro?: string, digits = 2): string {
  if (micro === undefined || !/^-?\d+$/.test(micro)) return '—';
  const value = BigInt(micro);
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const precision = Math.max(2, digits);
  const scale = 10n ** BigInt(precision);
  const rounded = (absolute * scale + 500_000n) / 1_000_000n;
  const whole = (rounded / scale).toLocaleString('en-US');
  const fraction = String(rounded % scale)
    .padStart(precision, '0')
    .slice(0, digits);
  return `${negative ? '−' : ''}$${whole}${digits ? '.' + fraction : ''}`;
}
export function compact(value?: string | number | bigint) {
  if (value == null) return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(n);
}
// Whole number with thousands separators. Decimal strings stay exact past 2^53.
export function count(value?: string | number | bigint | null) {
  if (typeof value === 'string')
    return /^\d+$/.test(value) ? BigInt(value).toLocaleString('en-US') : '—';
  if (typeof value === 'bigint') return value.toLocaleString('en-US');
  return value == null || !Number.isFinite(value) ? '—' : Math.round(value).toLocaleString('en-US');
}
export function age(at?: number) {
  if (!at) return 'Not observed';
  const seconds = Math.max(0, Date.now() / 1000 - at);
  return seconds < 60
    ? 'Just now'
    : seconds < 3600
      ? `${Math.floor(seconds / 60)}m ago`
      : `${Math.floor(seconds / 3600)}h ago`;
}
// Hour and minute of an epoch-seconds instant, for chart axes and intervals.
export const timeOfDay = (at: number) =>
  new Date(at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
// Time of day when `at` falls on the same local day as `now`, otherwise date and time.
export function clockTime(at: number, now: number) {
  const date = new Date(at * 1000);
  const today = date.toDateString() === new Date(now * 1000).toDateString();
  return date.toLocaleString(
    [],
    today
      ? { hour: 'numeric', minute: '2-digit' }
      : { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' },
  );
}
export function gb(n?: number) {
  return n == null ? '—' : `${n.toFixed(1)} GB`;
}

export const shortModelName = (id: string) => id.split('/').pop() || id;
