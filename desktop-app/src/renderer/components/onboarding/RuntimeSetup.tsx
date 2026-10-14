import { Download } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button, Notice } from '../UI';

type Copy = { title: string; lead: string; action: string };

const firstRun: Record<'missing' | 'failed', Copy> = {
  missing: {
    title: 'Install Darkbloom to check this Mac.',
    lead: 'Darkbloom installs its verified native runtime, then checks whether this Mac can serve models. Your provider works independently of this window.',
    action: 'Install runtime',
  },
  failed: {
    title: 'We couldn’t check this Mac.',
    lead: 'Darkbloom couldn’t reach its native runtime. Repair it and the check runs again.',
    action: 'Repair runtime',
  },
};

// Returning users set Darkbloom up before: say what happened to it, not how the first check works.
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

export function RuntimeSetup({
  backend,
  returningUser = false,
}: {
  backend: BackendState;
  returningUser?: boolean;
}) {
  const [error, setError] = useState('');
  const { state } = backend.status;
  const copy = returningUser
    ? returning[state === 'missing' || state === 'incompatible' ? state : 'failed']
    : firstRun[state === 'missing' ? 'missing' : 'failed'];
  async function install() {
    try {
      setError('');
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    }
  }
  return (
    <>
      <h2>{copy.title}</h2>
      <p>{copy.lead}</p>
      {error && <Notice>{error}</Notice>}
      {backend.status.message && <p className="muted">{backend.status.message}</p>}
      <Button variant="primary" disabled={!api} onClick={() => void install()}>
        <Download size={16} /> {copy.action}
      </Button>
    </>
  );
}
