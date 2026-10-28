import { Download, LoaderCircle, RefreshCw, RotateCw, X } from 'lucide-react';
import { useState } from 'react';
import type { DesktopStatus } from '../../../shared/contracts';
import { supportsNewProviders } from '../../../shared/macos';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { openSoftwareUpdate } from '../../softwareUpdate';
import { GetHelp } from '../Help';
import { Button, Notice } from '../UI';

// The button each status offers; other statuses are waiting on the CLI. Nothing installs until
// the user clicks one.
const actions: Partial<Record<DesktopStatus['state'], string>> = {
  missing: 'Install CLI',
  error: 'Repair CLI',
  incompatible: 'Update CLI',
};

type Copy = { title: string; lead: string; action: string };

// Returning users set Darkbloom up before: say what happened to its CLI, not how the first run
// works.
const returning: Record<'missing' | 'incompatible' | 'failed', Copy> = {
  missing: {
    title: 'Reinstall the Darkbloom CLI to continue.',
    lead: 'The Darkbloom CLI is no longer installed on this Mac.',
    action: 'Install CLI',
  },
  incompatible: {
    title: 'Update the Darkbloom CLI to continue.',
    lead: 'Darkbloom reached its CLI on this Mac, but the installed version doesn’t work with this version of the app.',
    action: 'Update CLI',
  },
  failed: {
    title: 'Darkbloom couldn’t start.',
    lead: 'The app couldn’t start or connect to the Darkbloom CLI on this Mac. Repair it to continue.',
    action: 'Repair CLI',
  },
};

// Onboarding's first step, Install the Darkbloom CLI, and the returning-user Startup screen when
// the CLI is unreachable. It offers an install, repair or update when one is needed, and shows
// whatever the main process reports while the CLI connects or while an install the user started
// runs.
export function RuntimeSetup({
  backend,
  returningUser = false,
}: {
  backend: BackendState;
  returningUser?: boolean;
}) {
  // New providers need macOS 27 or later. A Mac that already has the CLI (any status but
  // missing), or a returning user reinstalling it, is an existing provider and carries on; the
  // coordinator decides whether it serves.
  const version = backend.system?.macosVersion;
  if (!returningUser && backend.status.state === 'missing' && !supportsNewProviders(version))
    return <MacOSRequired version={version!} />;
  return <InstallCLI backend={backend} returningUser={returningUser} />;
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

function InstallCLI({ backend, returningUser }: { backend: BackendState; returningUser: boolean }) {
  const [error, setError] = useState('');
  const [pending, setPending] = useState(false);
  const { state, message, installFailed } = backend.status;
  // While the install the user started runs, offer only a way out, never a second install.
  const installing = state === 'installing';
  // The last install failed: `message` names the step that failed and the installer's reason.
  const failed = !installing && !!installFailed;
  const copy = returningUser
    ? returning[
        state === 'missing' || state === 'incompatible' ? state : installing ? 'missing' : 'failed'
      ]
    : undefined;
  const action = installing ? undefined : failed ? 'Retry' : copy ? copy.action : actions[state];
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
      <h2>{copy ? copy.title : 'Install the Darkbloom CLI'}</h2>
      <p>
        {copy
          ? copy.lead
          : 'Darkbloom runs on its command-line tool. It installs once, runs a background service that serves models on this Mac, and updates automatically.'}
      </p>
      {error && <Notice>{error}</Notice>}
      {/* One live region for the progress and the reason, so each change is announced. */}
      <p className="install-status" role="status">
        {!action && <LoaderCircle className="spin" size={14} aria-hidden="true" />}
        {message ||
          (action
            ? ''
            : installing
              ? 'Installing the Darkbloom CLI…'
              : 'Connecting to the Darkbloom CLI…')}
      </p>
      {installing ? (
        <Button disabled={!api} onClick={() => void api?.cancelInstall()}>
          <X size={16} /> Cancel
        </Button>
      ) : (
        action && (
          <Button variant="primary" disabled={!api || pending} onClick={() => void install()}>
            {failed ? <RotateCw size={16} /> : <Download size={16} />} {action}
          </Button>
        )
      )}
      {(error || failed) && (
        <p className="get-help">
          <GetHelp />
        </p>
      )}
    </>
  );
}
