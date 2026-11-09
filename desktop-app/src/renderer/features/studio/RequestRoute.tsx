import { useEffect, useId, useState, type FormEvent } from 'react';
import { KeyRound } from 'lucide-react';
import type { LocalServing, RequestRoute as Route } from '../../../shared/localServing';
import type { BackendState } from '../../useBackend';
import { Button, Status } from '../../components/UI';
import { ChoiceCard } from './ChoiceCard';
import { effectiveRoute, keyRefusal, routeChoices } from './words';
import styles from './studio.module.css';

// Where your requests go when this Mac can't take them (`darkbloom route …`). A running local API
// uses a saved route from its next request, so saving restarts nothing. Your other Macs and the
// network need the account API key, which only `route_key` ever carries.
export function RequestRoute({ backend, local }: { backend: BackendState; local: LocalServing }) {
  const heading = useId();
  const group = useId();
  const current = effectiveRoute(local);
  const [draft, setDraft] = useState<Route>(current);
  useEffect(() => setDraft(current), [current]);
  const needsKey = (route: Route) => route !== 'this-mac' && !local.route_key;
  return (
    <section className="settings-section" aria-labelledby={heading}>
      <h2 id={heading}>When this Mac can’t take a request</h2>
      <fieldset className={styles.choices} aria-labelledby={heading}>
        {routeChoices.map((choice) => (
          <ChoiceCard
            key={choice.route}
            name={group}
            checked={draft === choice.route}
            disabled={needsKey(choice.route)}
            onSelect={() => setDraft(choice.route)}
            title={choice.title}
            detail={choice.detail}
            hint={needsKey(choice.route) ? 'Needs your account API key.' : undefined}
          />
        ))}
      </fieldset>
      <div className={styles.apply}>
        <Button
          disabled={draft === current || needsKey(draft) || backend.busy}
          onClick={() => void backend.act({ action: 'route', route: draft }, true)}
        >
          Save
        </Button>
      </div>
      <AccountKey backend={backend} saved={local.route_key} />
    </section>
  );
}

// The account API key goes from the field straight into `route_key` and is cleared as it is sent:
// it is never shown, kept or read back. The runtime says only whether one is saved.
function AccountKey({ backend, saved }: { backend: BackendState; saved: boolean }) {
  const inputId = useId();
  const errorId = useId();
  const [replacing, setReplacing] = useState(false);
  const [value, setValue] = useState('');
  useEffect(() => {
    if (!saved) setReplacing(false);
  }, [saved]);
  if (saved && !replacing)
    return (
      <div className="setting-row">
        <span>
          <strong>Account API key</strong>
          <small>Saved in this Mac’s Keychain.</small>
        </span>
        <Status state="online">Key saved</Status>
        <Button variant="quiet" disabled={backend.busy} onClick={() => setReplacing(true)}>
          Replace
        </Button>
      </div>
    );
  const key = value.trim();
  const refusal = key ? keyRefusal(key) : undefined;
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!key || refusal || backend.busy) return;
    setValue('');
    if (await backend.act({ action: 'route_key', key }, true)) setReplacing(false);
  };
  return (
    <form className="setting-row" onSubmit={(event) => void submit(event)}>
      <span>
        <label htmlFor={inputId}>
          <strong>Account API key</strong>
        </label>
        <small>From the Darkbloom console. A self-route-only key is safest.</small>
      </span>
      <span className={styles.field}>
        <span className={styles.keyControls}>
          <input
            id={inputId}
            className={styles.keyInput}
            type="password"
            autoComplete="off"
            autoCapitalize="off"
            spellCheck={false}
            value={value}
            aria-invalid={!!refusal}
            aria-describedby={refusal ? errorId : undefined}
            onChange={(event) => setValue(event.target.value)}
          />
          <Button type="submit" disabled={!key || !!refusal || backend.busy}>
            <KeyRound size={14} /> Save key
          </Button>
          {saved && (
            <Button
              type="button"
              variant="quiet"
              onClick={() => {
                setValue('');
                setReplacing(false);
              }}
            >
              Cancel
            </Button>
          )}
        </span>
        {refusal && (
          <small id={errorId} className={styles.error} role="alert">
            {refusal}
          </small>
        )}
      </span>
    </form>
  );
}
