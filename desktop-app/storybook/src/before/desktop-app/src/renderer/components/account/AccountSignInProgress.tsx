import { ArrowUpRight, Check, Copy, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { Operation } from '../../../shared/contracts';
import { api, type BackendState } from '../../useBackend';
import styles from './account.module.css';

export function AccountSignInProgress({
  backend,
  operation,
  requestFailed,
  submitting,
  onRetry,
  onClose,
}: {
  backend: BackendState;
  operation?: Operation;
  requestFailed: boolean;
  submitting: boolean;
  onRetry: () => void;
  onClose: () => void;
}) {
  const complete = operation?.state === 'succeeded' || backend.state?.account?.signed_in;
  const failed = requestFailed || operation?.state === 'failed' || operation?.state === 'cancelled';
  const code = operation?.state === 'running' ? backend.state?.link?.code : undefined;
  const [copied, setCopied] = useState('');
  const [error, setError] = useState('');
  const [openedOperation, setOpenedOperation] = useState('');
  const browserOpened = !!operation && openedOperation === operation.id;
  async function copyCode() {
    if (!code || !api) return;
    try {
      await api.copy(code);
      setCopied(code);
      setError('');
    } catch {
      setError('Could not copy the connection code.');
    }
  }
  async function openSignIn() {
    try {
      await api?.openExternal('link');
      setOpenedOperation(operation?.id ?? '');
      setError('');
    } catch {
      setError('Could not open sign-in. Try again.');
    }
  }

  if (complete)
    return (
      <div aria-live="polite">
        <p className={styles.state}>
          <Check size={18} /> You’re signed in.
        </p>
        <button className="button primary" onClick={onClose}>
          Done
        </button>
      </div>
    );
  if (failed)
    return (
      <div aria-live="polite">
        <p className={styles.hint}>
          {operation?.state === 'cancelled' ? 'Sign-in cancelled.' : 'Could not complete sign-in.'}
        </p>
        {operation?.state === 'failed' && (
          <details className={styles.details}>
            <summary>Details</summary>
            <pre>{operation.message}</pre>
          </details>
        )}
        {requestFailed && backend.error && (
          <p role="alert" className={styles.hint}>
            {backend.error}
          </p>
        )}
        <button className="button primary" disabled={backend.busy || submitting} onClick={onRetry}>
          Try again
        </button>
      </div>
    );
  return (
    <div aria-live="polite">
      {!code && (
        <p className={styles.state}>
          <LoaderCircle className="spin" size={15} /> Getting a connection code…
        </p>
      )}
      {code && (
        <>
          <p className={styles.instruction}>
            {browserOpened
              ? 'Approve the connection in your browser.'
              : 'Enter this code in your browser.'}
          </p>
          <div className={styles.codeRow}>
            <div>
              <span className={styles.label}>Sign-in code</span>
              <strong className={styles.code} aria-label={`Connection code ${code}`}>
                {code}
              </strong>
            </div>
            <button className="button secondary" onClick={() => void copyCode()}>
              {copied === code ? <Check size={15} /> : <Copy size={15} />}
              {copied === code ? 'Copied' : 'Copy code'}
            </button>
          </div>
          {browserOpened && (
            <p className={styles.state}>
              <LoaderCircle className="spin" size={15} /> Waiting for approval
            </p>
          )}
        </>
      )}
      {error && (
        <p role="alert" className={styles.hint}>
          {error}
        </p>
      )}
      <footer className={styles.signInActions}>
        <button className="button primary" disabled={!code} onClick={() => void openSignIn()}>
          Continue in browser <ArrowUpRight size={15} />
        </button>
        {operation?.cancellable && (
          <button
            className="button quiet"
            onClick={() => void backend.act({ action: 'cancel', operation: operation.id })}
          >
            Cancel
          </button>
        )}
      </footer>
    </div>
  );
}
