import { Download, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { DesktopStatus } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { GetHelp } from '../Help';
import { Button, Notice } from '../UI';

// The action each status offers during onboarding; other statuses are waiting on the backend.
const actions: Partial<Record<DesktopStatus['state'], string>> = {
  missing: 'Install backend',
  error: 'Repair backend',
  incompatible: 'Update backend',
};

type Copy = { title: string; lead: string; action: string };

// Returning users set Darkbloom up before: say what happened to it, not how the first run works.
const returning: Record<'missing' | 'incompatible' | 'failed', Copy> = {
  missing: {
    title: 'Reinstall Darkbloom to continue.',
    lead: 'Darkbloom’s native runtime is no longer installed on this Mac.',
    action: 'Reinstall runtime',
  },
  incompatible: {
    title: 'Update Darkbloom to continue.',
    lead: 'Darkbloom reached its native runtime on this Mac, but the installed version doesn’t work with this version of the app.',
    action: 'Update runtime',
  },
  failed: {
    title: 'Darkbloom couldn’t start.',
    lead: 'The app couldn’t start or connect to Darkbloom’s native runtime on this Mac. Repair it to continue.',
    action: 'Repair runtime',
  },
};

// Onboarding's first step, and the returning-user Startup screen when the runtime is
// unreachable. It shows whatever the main process reports while the backend installs or
// connects, and offers an install, repair or update only when one is needed.
export function RuntimeSetup({
  backend,
  returningUser = false,
}: {
  backend: BackendState;
  returningUser?: boolean;
}) {
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  const { state, message } = backend.status;
  const copy = returningUser
    ? returning[state === 'missing' || state === 'incompatible' ? state : 'failed']
    : undefined;
  const action = copy ? copy.action : actions[state];
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
      <h2>{copy ? copy.title : 'Install backend'}</h2>
      <p>
        {copy
          ? copy.lead
          : 'Darkbloom needs its backend, a background service that serves models on this Mac. It installs once and updates automatically.'}
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
      {error && (
        <p>
          <GetHelp />
        </p>
      )}
    </>
  );
}
