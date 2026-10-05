import type { BackendState } from '../useBackend';
import { api } from '../useBackend';

export function AccountControl({ backend }: { backend: BackendState }) {
  const state = backend.state;
  if (!state?.capabilities?.includes('account-signin')) return null;
  const signedIn = state.account?.signed_in;
  const pending = state.operations.find(
    (operation) => operation.action === 'account-signin' && operation.state === 'running',
  );
  return (
    <div className="account-control">
      <button
        disabled={backend.busy}
        onClick={() =>
          void backend.act({ action: signedIn ? 'account-signout' : 'account-signin' })
        }
      >
        {signedIn ? 'Sign out' : pending ? 'Signing in…' : 'Sign in'}
      </button>
      {pending && state.link && (
        <div role="status">
          <strong>{state.link.code}</strong>
          <button onClick={() => void api?.openExternal('link')}>Open sign-in</button>
          <button onClick={() => void backend.act({ action: 'cancel', operation: pending.id })}>
            Cancel
          </button>
        </div>
      )}
    </div>
  );
}
