import { ChevronRight, UserRound } from 'lucide-react';
import { useCallback, useState } from 'react';
import { createPortal } from 'react-dom';
import type { BackendState } from '../useBackend';
import { Modal } from './UI';
import { AccountSignInProgress } from './account/AccountSignInProgress';
import { useAccountSignIn } from './account/useAccountSignIn';
import styles from './account/account.module.css';

export function AccountControl({ backend }: { backend: BackendState }) {
  const [dialog, setDialog] = useState<'account' | 'signin' | null>(null);
  const close = useCallback(() => setDialog(null), []);
  const login = useAccountSignIn(backend);
  const state = backend.state;
  if (!state?.capabilities?.includes('account-signin')) return null;
  const signedIn = state.account?.signed_in;
  const email = signedIn ? state.account?.email?.trim() : undefined;
  const label = signedIn ? 'Account' : login.pending ? 'Continue sign-in' : 'Sign in';

  function open() {
    setDialog(signedIn ? 'account' : 'signin');
    if (!signedIn) void login.begin();
  }

  return (
    <>
      <button
        className={styles.control}
        aria-label={email ? `Account ${email}` : label}
        aria-haspopup="dialog"
        disabled={!signedIn && !login.pending && (backend.busy || login.submitting)}
        onClick={open}
      >
        <span className={styles.icon}>
          <UserRound size={17} />
        </span>
        <span className={styles.identity}>
          <strong title={email}>{email || label}</strong>
          <small>
            {signedIn ? 'Signed in' : login.pending ? 'Waiting for approval' : 'Darkbloom account'}
          </small>
        </span>
        <ChevronRight size={14} className={styles.chevron} />
      </button>
      {dialog &&
        createPortal(
          <Modal
            title={dialog === 'account' ? 'Your account' : 'Sign in to Darkbloom'}
            onClose={close}
          >
            {dialog === 'account' ? (
              <>
                <p className={styles.hint}>
                  {email ? (
                    <>
                      <strong className={styles.accountEmail}>{email}</strong>Signed in
                    </>
                  ) : (
                    'You’re signed in to Darkbloom.'
                  )}
                </p>
                <div className={styles.actions}>
                  <button
                    className="button secondary"
                    disabled={backend.busy}
                    onClick={async () => {
                      if (await backend.act({ action: 'account-signout' })) close();
                    }}
                  >
                    Sign out
                  </button>
                  <button className="button primary" onClick={close}>
                    Done
                  </button>
                </div>
              </>
            ) : (
              <AccountSignInProgress
                backend={backend}
                operation={login.operation}
                requestFailed={login.requestFailed}
                submitting={login.submitting}
                onRetry={() => void login.begin()}
                onClose={close}
              />
            )}
          </Modal>,
          document.body,
        )}
    </>
  );
}
