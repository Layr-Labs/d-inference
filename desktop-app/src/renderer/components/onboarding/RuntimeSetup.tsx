import { Download, RotateCw, X } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button, Notice } from '../UI';

export function RuntimeSetup({ backend }: { backend: BackendState }) {
  const [error, setError] = useState('');
  const missing = backend.status.state === 'missing';
  async function install() {
    try {
      setError('');
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    }
  }
  // The app installs a missing runtime by itself; while it does, show its progress and offer
  // only a way out, never a second install.
  if (backend.status.state === 'installing')
    return (
      <>
        <h2>Installing the backend…</h2>
        <p>Darkbloom downloads and verifies its backend. This takes a few minutes.</p>
        <p className="muted" role="status">
          {backend.status.message || 'Preparing to install the backend…'}
        </p>
        <Button disabled={!api} onClick={() => void api?.cancelInstall()}>
          <X size={16} /> Cancel
        </Button>
      </>
    );
  // The message names the step that failed and the installer's reason.
  if (backend.status.installFailed)
    return (
      <>
        <h2>The backend isn’t installed yet.</h2>
        <p role="alert">{backend.status.message}</p>
        <Button variant="primary" disabled={!api} onClick={() => void install()}>
          <RotateCw size={16} /> Retry
        </Button>
      </>
    );
  return (
    <>
      <h2>{missing ? 'Install Darkbloom to check this Mac.' : 'We couldn’t check this Mac.'}</h2>
      <p>
        {missing
          ? 'Darkbloom installs its verified native runtime, then checks whether this Mac can serve models. Your provider works independently of this window.'
          : 'Darkbloom couldn’t reach its native runtime. Repair it and the check runs again.'}
      </p>
      {error && <Notice>{error}</Notice>}
      {backend.status.message && <p className="muted">{backend.status.message}</p>}
      <Button variant="primary" disabled={!api} onClick={() => void install()}>
        <Download size={16} /> {missing ? 'Install runtime' : 'Repair runtime'}
      </Button>
    </>
  );
}
