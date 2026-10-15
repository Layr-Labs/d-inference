import { Download, RotateCw, X } from 'lucide-react';
import { useState } from 'react';
import type { DesktopStatus } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button, Notice } from '../UI';

// The button each status offers. Nothing installs until the user clicks one.
const actions: Partial<Record<DesktopStatus['state'], string>> = {
  missing: 'Install CLI',
  error: 'Repair CLI',
  incompatible: 'Update CLI',
};
const lead =
  'Darkbloom runs on its command-line tool. It installs once, runs a background service that serves models on this Mac, and updates automatically.';

export function RuntimeSetup({ backend }: { backend: BackendState }) {
  const [error, setError] = useState('');
  const { state, message, installFailed } = backend.status;
  async function install() {
    try {
      setError('');
      await api?.install();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Installation failed');
    }
  }
  // While the install the user started runs, show its progress and offer only a way out,
  // never a second install.
  if (state === 'installing')
    return (
      <>
        <h2>Installing the Darkbloom CLI…</h2>
        <p>Darkbloom downloads and verifies its CLI. This takes a few minutes.</p>
        <p className="muted" role="status">
          {message || 'Installing the Darkbloom CLI…'}
        </p>
        <Button disabled={!api} onClick={() => void api?.cancelInstall()}>
          <X size={16} /> Cancel
        </Button>
      </>
    );
  // The message names the step that failed and the installer's reason.
  if (installFailed)
    return (
      <>
        <h2>Install the Darkbloom CLI</h2>
        <p role="alert">{message}</p>
        <Button variant="primary" disabled={!api} onClick={() => void install()}>
          <RotateCw size={16} /> Retry
        </Button>
      </>
    );
  return (
    <>
      <h2>Install the Darkbloom CLI</h2>
      <p>{lead}</p>
      {error && <Notice>{error}</Notice>}
      {message && <p className="muted">{message}</p>}
      <Button variant="primary" disabled={!api} onClick={() => void install()}>
        <Download size={16} /> {actions[state] || 'Repair CLI'}
      </Button>
    </>
  );
}
