export function money(micro?: string, digits = 2): string {
  if (micro === undefined || !/^-?\d+$/.test(micro)) return '—';
  const value = BigInt(micro);
  const negative = value < 0n;
  const absolute = negative ? -value : value;
  const cents = (absolute + 5000n) / 10000n;
  const whole = (cents / 100n).toLocaleString('en-US');
  return `${negative ? '−' : ''}$${whole}${digits ? '.' + String(cents % 100n).padStart(2, '0') : ''}`;
}
export function compact(value?: string | number) {
  if (value == null) return '—';
  const n = Number(value);
  if (!Number.isFinite(n)) return '—';
  return Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(n);
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
export function gb(n?: number) {
  return n == null ? '—' : `${n.toFixed(1)} GB`;
}
