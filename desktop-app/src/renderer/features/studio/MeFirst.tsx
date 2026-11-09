import { useEffect, useId, useState } from 'react';
import { Pause } from 'lucide-react';
import type { LocalServing } from '../../../shared/localServing';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { backIn, idleMinutes, meFirstRange } from './words';
import styles from './studio.module.css';

// Both, me first: whether Darkbloom pauses while you use this Mac, and for how long it stays
// paused after your last request. A serving process reads both when it starts, so a change made
// while serving applies at the next restart.
export function MeFirst({ backend, local }: { backend: BackendState; local: LocalServing }) {
  const state = backend.state!;
  const heading = useId();
  const errorId = useId();
  const [on, setOn] = useState(local.me_first);
  const [idle, setIdle] = useState(String(local.me_first_idle_minutes));
  useEffect(() => {
    setOn(local.me_first);
    setIdle(String(local.me_first_idle_minutes));
  }, [local.me_first, local.me_first_idle_minutes]);
  const [restart, setRestart] = useState(false);
  const value = idleMinutes(idle);
  const invalid = on && value === undefined;
  const changed = on !== local.me_first || (on && value !== local.me_first_idle_minutes);
  const paused =
    local.paused_until != null ? backIn(local.paused_until - state.observed_at) : undefined;
  const save = async () => {
    const saved = await backend.act(
      {
        action: 'local_settings',
        me_first: on,
        me_first_idle_minutes: on && value !== undefined ? value : local.me_first_idle_minutes,
      },
      true,
    );
    if (saved && state.state !== 'stopped') setRestart(true);
  };
  return (
    <section className="settings-section" aria-labelledby={heading}>
      <h2 id={heading}>Me first</h2>
      {paused && (
        <p className={styles.paused} role="status">
          <Pause size={14} aria-hidden="true" />
          <span>
            <strong>Darkbloom is paused for you</strong> · {paused}
          </span>
        </p>
      )}
      <label className="setting-row">
        <span>
          <strong>Pause Darkbloom while you use this Mac</strong>
          <small>
            {on
              ? 'Darkbloom sends no new requests while yours run.'
              : 'Darkbloom keeps serving while you use the local API.'}
          </small>
        </span>
        <input
          className="switch"
          type="checkbox"
          role="switch"
          checked={on}
          onChange={(event) => setOn(event.target.checked)}
        />
      </label>
      {on && (
        <div className="setting-row">
          <span>
            <strong>Back after</strong>
            <small>Minutes with none of your requests before Darkbloom comes back.</small>
          </span>
          <span className={styles.field}>
            <span className={styles.minutes}>
              <input
                type="number"
                inputMode="numeric"
                min={meFirstRange.min}
                max={meFirstRange.max}
                step={1}
                aria-label="Minutes before Darkbloom comes back"
                aria-invalid={invalid}
                aria-describedby={invalid ? errorId : undefined}
                value={idle}
                onChange={(event) => setIdle(event.target.value)}
              />
              minutes
            </span>
            {invalid && (
              <small id={errorId} className={styles.error} role="alert">
                From 1 to 120 minutes.
              </small>
            )}
          </span>
        </div>
      )}
      <div className={styles.apply}>
        <Button
          disabled={!changed || invalid || backend.busy}
          onClick={() => {
            setRestart(false);
            void save();
          }}
        >
          Save
        </Button>
        {restart && (
          <>
            <small role="status">Saved. Restart serving to apply.</small>
            <Button
              disabled={backend.busy}
              onClick={async () => {
                if (await backend.act({ action: 'restart' }, true)) setRestart(false);
              }}
            >
              Restart serving
            </Button>
          </>
        )}
      </div>
    </section>
  );
}
