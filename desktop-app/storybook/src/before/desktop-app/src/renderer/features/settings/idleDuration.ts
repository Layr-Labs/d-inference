export type IdleUnit = 'minutes' | 'hours';

export interface IdleDraft {
  keepLoaded: boolean;
  amount: string;
  unit: IdleUnit;
}

// Native `IdleUnloadPolicy.maxMinutes`: the desktop API rejects longer idle periods.
export const maxIdleMinutes = 7 * 24 * 60;
export const idlePresets = [15, 60, 240];
const defaultIdleMinutes = 60;
const unitMinutes: Record<IdleUnit, number> = { minutes: 1, hours: 60 };

export function durationFields(minutes: number): Pick<IdleDraft, 'amount' | 'unit'> {
  return minutes % 60 === 0
    ? { amount: String(minutes / 60), unit: 'hours' }
    : { amount: String(minutes), unit: 'minutes' };
}

// `idle_minutes: 0` keeps models loaded; the duration fields still hold the default to restore.
export function idleDraft(minutes: number): IdleDraft {
  return minutes > 0
    ? { keepLoaded: false, ...durationFields(minutes) }
    : { keepLoaded: true, ...durationFields(defaultIdleMinutes) };
}

export function formatDuration(minutes: number) {
  return minutes % 60 === 0 ? `${minutes / 60} h` : `${minutes} min`;
}

function rawMinutes({ amount, unit }: Pick<IdleDraft, 'amount' | 'unit'>) {
  return amount.trim() === '' ? NaN : Number(amount) * unitMinutes[unit];
}

export function durationError(draft: Pick<IdleDraft, 'amount' | 'unit'>) {
  const minutes = rawMinutes(draft);
  if (!Number.isFinite(minutes)) return 'Enter how long models stay loaded.';
  if (minutes < 1) return 'Use at least 1 minute.';
  if (minutes > maxIdleMinutes) return 'Use at most 7 days (168 hours).';
  if (Math.abs(minutes - Math.round(minutes)) > 1e-9) return 'Use whole minutes.';
  return undefined;
}

// The `idle_minutes` to save, or undefined while the custom duration is invalid.
export function idleMinutes(draft: IdleDraft) {
  if (draft.keepLoaded) return 0;
  return durationError(draft) ? undefined : Math.round(rawMinutes(draft));
}
