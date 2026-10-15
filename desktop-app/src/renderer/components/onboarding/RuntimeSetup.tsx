import { Download, LoaderCircle, RefreshCw } from 'lucide-react';
import { useState } from 'react';
import type { DesktopStatus } from '../../../shared/contracts';
import { supportsNewProviders } from '../../../shared/macos';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { openSoftwareUpdate } from '../../softwareUpdate';
import { Button, Notice } from '../UI';

// The button each status offers; other statuses are waiting on the CLI. Nothing installs until
// the user clicks one.
const actions: Partial<Record<DesktopStatus['state'], string>> = {
  missing: 'Install CLI',
  error: 'Repair CLI',
  incompatible: 'Update CLI',
};

// Onboarding's first step, Install the Darkbloom CLI. It offers an install, repair or update
// when one is needed, and shows whatever the main process reports while the CLI connects or
// while an install the user started runs.
export function RuntimeSetup({ backend }: { backend: BackendState }) {
  const { state, message } = backend.status;
  // New providers need macOS 27 or later. A Mac that already has the CLI (any status but
  // missing) is an existing provider and carries on; the coordinator decides whether it serves.
  const version = backend.system?.macosVersion;
  if (state === 'missing' && !supportsNewProviders(version))
    return <MacOSRequired version={version!} />;
  return <InstallCLI state={state} message={message} />;
}

function MacOSRequired({ version }: { version: string }) {
  return (
    <>
      <h2>Darkbloom needs macOS 27 or later</h2>
      <p>
        New Macs can join Darkbloom on macOS 27 or later. This Mac runs macOS {version}. Update
        macOS, then reopen Darkbloom.
      </p>
      <Button variant="primary" disabled={!api} onClick={openSoftwareUpdate}>
        <RefreshCw size={16} /> Open Software Update
      </Button>
    </>
  );
}

function InstallCLI({ state, message }: DesktopStatus) {
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
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
      <h2>Install the Darkbloom CLI</h2>
      <p>
        Darkbloom runs on its command-line tool. It installs once, runs a background service that
        serves models on this Mac, and updates automatically.
      </p>
      {error && <Notice>{error}</Notice>}
      {/* One live region for both the progress and the reason, so each change is announced. */}
      <p className="install-status" role="status">
        {!action && <LoaderCircle className="spin" size={14} aria-hidden="true" />}
        {message ||
          (action
            ? ''
            : state === 'installing'
              ? 'Installing the Darkbloom CLI…'
              : 'Connecting to the Darkbloom CLI…')}
      </p>
      {action && (
        <Button variant="primary" disabled={!api || pending} onClick={() => void install()}>
          <Download size={16} /> {action}
        </Button>
      )}
    </>
  );
}
