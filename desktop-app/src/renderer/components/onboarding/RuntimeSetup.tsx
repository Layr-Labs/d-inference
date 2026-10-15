import { Download, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { DesktopStatus } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button, Notice } from '../UI';

// The action each status offers; other statuses are waiting on the backend.
const actions: Partial<Record<DesktopStatus['state'], string>> = {
  missing: 'Install backend',
  error: 'Repair backend',
  incompatible: 'Update backend',
};

// Onboarding's first step. It shows whatever the main process reports while the backend
// installs or connects, and offers an install, repair or update only when one is needed.
export function RuntimeSetup({ backend }: { backend: BackendState }) {
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  const { state, message } = backend.status;
  const action = actions[state];
  async function install() {
    try {
      setError('');
      setPending(true);
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    } finally {
      setPending(false);
    }
  }
  return (
    <>
      <h2>Install backend</h2>
      <p>
        Darkbloom needs its backend, a background service that serves models on this Mac. It
        installs once and updates automatically.
      </p>
      {error && <Notice>{error}</Notice>}
      {/* One live region for both the progress and the reason, so each change is announced. */}
      <p className="install-status" role="status">
        {!action && <LoaderCircle className="spin" size={14} aria-hidden="true" />}
        {message ||
          (action
            ? ''
            : state === 'installing'
              ? 'Installing the backend…'
              : 'Connecting to the backend…')}
      </p>
      {action && (
        <Button variant="primary" disabled={!api || pending} onClick={() => void install()}>
          <Download size={16} /> {action}
        </Button>
      )}
    </>
  );
}
