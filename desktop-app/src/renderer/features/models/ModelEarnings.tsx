import { money } from '../insights/types';
import type { ModelEarnings } from './earnings';

export function ModelEarningsAmount({
  model,
  earnings,
}: {
  model: string;
  earnings: ModelEarnings;
}) {
  return (
    <span
      className="model-earned"
      title={
        earnings?.historyComplete === false
          ? 'Settled account earnings · available history'
          : 'Settled account earnings · past 30 days'
      }
    >
      {earnings ? money(earnings.get(model) ?? 0n) : '—'}
    </span>
  );
}

export function ModelEarningsOrder({
  earnings,
  error,
  linked,
  available = true,
}: {
  earnings: ModelEarnings;
  error: string | null;
  linked: boolean;
  /** False when a linked Mac is signed out, so earnings cannot be read. */
  available?: boolean;
}) {
  return (
    <div className="model-earnings-order" title={error ?? undefined}>
      <span>Most earned · {earnings?.historyComplete === false ? 'Recent' : '30d'}</span>
      {!earnings && (
        <span className="muted">
          {!linked
            ? 'Account not linked'
            : !available
              ? 'Sign in to see earnings'
              : error
                ? 'Unavailable'
                : 'Loading…'}
        </span>
      )}
      {!!earnings && !!error && <span className="muted">Last update</span>}
    </div>
  );
}
