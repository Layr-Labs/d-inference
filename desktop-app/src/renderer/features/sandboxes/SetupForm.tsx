import { useEffect, useId, useState } from 'react';
import { sandboxSlotLimits } from '../../../shared/sandbox';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { setupRequest, type SetupChoice } from './setup';
import styles from './sandboxes.module.css';

// Jobs at a time for each platform: Linux 0 to 16, macOS 0 to 2.
export function SlotInputs({
  linux,
  macos,
  error,
  onChange,
}: {
  linux: string;
  macos: string;
  error?: string;
  onChange: (next: { linux?: string; macos?: string }) => void;
}) {
  const errorID = useId();
  return (
    <div className={styles.counts}>
      <label>
        <span>Linux</span>
        <input
          className={styles.input}
          type="number"
          inputMode="numeric"
          min={0}
          max={sandboxSlotLimits.linux}
          step={1}
          value={linux}
          aria-invalid={!!error}
          aria-describedby={error ? errorID : undefined}
          onChange={(event) => onChange({ linux: event.target.value })}
        />
      </label>
      <label>
        <span>macOS</span>
        <input
          className={styles.input}
          type="number"
          inputMode="numeric"
          min={0}
          max={sandboxSlotLimits.macos}
          step={1}
          value={macos}
          aria-invalid={!!error}
          aria-describedby={error ? errorID : undefined}
          onChange={(event) => onChange({ macos: event.target.value })}
        />
      </label>
      <small id={errorID} className={styles.error} aria-live="polite">
        {error}
      </small>
    </div>
  );
}

// First setup: `darkbloom sandbox setup` with the owner's choices. Nothing is installed before
// the CLI's own checks pass, and the approval is one click in the browser.
export function SetupForm({ backend }: { backend: BackendState }) {
  const [choice, setChoice] = useState<SetupChoice>({
    automatic: true,
    linux: '1',
    macos: '1',
    disk: '',
    waitReady: false,
  });
  const update = (next: Partial<SetupChoice>) => setChoice((current) => ({ ...current, ...next }));
  const request = setupRequest(choice);
  const diskHint = useId();
  // Sent: the page follows the setup once its operation arrives with the next snapshot. A
  // refused one, or one that never shows, gives the button back.
  const [sent, setSent] = useState(false);
  useEffect(() => {
    if (!sent) return;
    const timer = setTimeout(() => setSent(false), 10_000);
    return () => clearTimeout(timer);
  }, [sent]);
  return (
    <form
      className={styles.form}
      aria-label="Set up Darkbloom Sandbox"
      noValidate
      onSubmit={(event) => {
        event.preventDefault();
        if (!request.action || sent) return;
        setSent(true);
        void backend.act(request.action).then((ok) => {
          if (!ok) setSent(false);
        });
      }}
    >
      <h2>Set up</h2>
      <fieldset className={styles.field}>
        <legend>Jobs at a time</legend>
        <div className={styles.choices}>
          <label data-selected={choice.automatic}>
            <input
              type="radio"
              name="sandbox-jobs"
              checked={choice.automatic}
              onChange={() => update({ automatic: true })}
            />
            <span>
              <strong>Automatic</strong>
              <small>What fits this Mac</small>
            </span>
          </label>
          <label data-selected={!choice.automatic}>
            <input
              type="radio"
              name="sandbox-jobs"
              checked={!choice.automatic}
              onChange={() => update({ automatic: false })}
            />
            <span>
              <strong>Choose</strong>
              <small>
                Linux 0–{sandboxSlotLimits.linux}, macOS 0–{sandboxSlotLimits.macos}
              </small>
            </span>
          </label>
        </div>
        {!choice.automatic && (
          <SlotInputs
            linux={choice.linux}
            macos={choice.macos}
            error={request.slotsError}
            onChange={update}
          />
        )}
      </fieldset>
      <div className={styles.field}>
        <label className={styles.fieldLabel}>
          <span>Work disk</span>
          <input
            className={styles.input}
            type="text"
            placeholder="/Volumes/FastSSD"
            spellCheck={false}
            autoCapitalize="off"
            autoCorrect="off"
            value={choice.disk}
            aria-invalid={!!request.diskError}
            aria-describedby={diskHint}
            onChange={(event) => update({ disk: event.target.value })}
          />
        </label>
        <small id={diskHint} className={request.diskError ? styles.error : styles.hint}>
          {request.diskError ??
            'Optional. An APFS drive with ownership on, for the VM images and jobs.'}
        </small>
      </div>
      <label className={styles.check}>
        <input
          type="checkbox"
          checked={choice.waitReady}
          onChange={(event) => update({ waitReady: event.target.checked })}
        />
        Wait until images are downloaded
      </label>
      <div className={styles.submit}>
        <Button variant="primary" type="submit" disabled={backend.busy || sent || !request.action}>
          {sent ? 'Setting up…' : 'Set up'}
        </Button>
        <small>You approve this Mac once, in your browser.</small>
      </div>
    </form>
  );
}
