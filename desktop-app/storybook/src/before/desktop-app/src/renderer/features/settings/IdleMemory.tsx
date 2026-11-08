import { useId } from 'react';
import {
  durationError,
  durationFields,
  formatDuration,
  idleMinutes,
  idlePresets,
  maxIdleMinutes,
  type IdleDraft,
  type IdleUnit,
} from './idleDuration';
import styles from './idleMemory.module.css';

export function IdleMemory({
  value,
  onChange,
}: {
  value: IdleDraft;
  onChange: (value: IdleDraft) => void;
}) {
  const errorId = useId();
  const error = value.keepLoaded ? undefined : durationError(value);
  const minutes = idleMinutes(value);
  return (
    <>
      <label className="setting-row">
        <span>
          <strong>Keep models loaded</strong>
          <small>
            {value.keepLoaded
              ? 'Models stay in memory while this Mac is idle.'
              : 'Idle models are unloaded to free memory.'}{' '}
            Apply changes by restarting the provider.
          </small>
        </span>
        <input
          className="switch"
          type="checkbox"
          role="switch"
          checked={value.keepLoaded}
          onChange={(event) => onChange({ ...value, keepLoaded: event.target.checked })}
        />
      </label>
      {!value.keepLoaded && (
        <div className="setting-row">
          <span>
            <strong>Free memory after</strong>
            <small>How long models stay loaded while idle, up to 7 days.</small>
          </span>
          <div className={styles.duration}>
            <div className={styles.controls}>
              <div className={styles.presets} role="group" aria-label="Quick durations">
                {idlePresets.map((preset) => (
                  <button
                    key={preset}
                    type="button"
                    aria-pressed={minutes === preset}
                    onClick={() => onChange({ ...value, ...durationFields(preset) })}
                  >
                    {formatDuration(preset)}
                  </button>
                ))}
              </div>
              <input
                className={styles.amount}
                type="number"
                inputMode="decimal"
                min={1}
                max={value.unit === 'hours' ? maxIdleMinutes / 60 : maxIdleMinutes}
                step="any"
                aria-label="Free memory after"
                aria-invalid={Boolean(error)}
                aria-describedby={error ? errorId : undefined}
                value={value.amount}
                onChange={(event) => onChange({ ...value, amount: event.target.value })}
              />
              <select
                className={styles.unit}
                aria-label="Duration unit"
                value={value.unit}
                onChange={(event) => onChange({ ...value, unit: event.target.value as IdleUnit })}
              >
                <option value="minutes">minutes</option>
                <option value="hours">hours</option>
              </select>
            </div>
            {error && (
              <small id={errorId} className={styles.error} role="alert">
                {error}
              </small>
            )}
          </div>
        </div>
      )}
    </>
  );
}
