import { useEffect, useRef } from 'react';
import { ArrowUpRight } from 'lucide-react';
import type { Operation, Route } from '../../../shared/contracts';
import type { SandboxStatus } from '../../../shared/sandbox';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { supports } from '../../capabilities';
import { Button, Header } from '../../components/UI';
import { useDismissedOperation } from '../../components/operations/useOperationDismissal';
import { useResource } from '../../data/useResource';
import { WaitlistCard } from '../waitlists/WaitlistCard';
import { NotInstalled } from './NotInstalled';
import { SandboxStatusCard } from './SandboxStatusCard';
import { SetupProgress } from './SetupProgress';
import { latestSetup } from './setup';
import { isInstalled } from './status';
import styles from './sandboxes.module.css';

const title = 'Sandboxes';
const description = 'Run Darkbloom Sandbox CI jobs on this Mac.';

// Darkbloom Sandbox: approved GitHub Actions jobs in Linux and macOS VMs on this Mac, run by the
// add-on DarkbloomSandbox.app (docs/provider/sandboxes.md). A runtime without the `sandbox`
// capability gets one line instead of controls it would refuse.
export function Sandboxes({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  if (!supports(backend.state, 'sandbox'))
    return (
      <>
        <Header title={title} description={description} />
        <p className={styles.note}>
          Darkbloom Sandbox needs a newer Darkbloom CLI.
          <button type="button" className="text-link" onClick={() => navigate('updates')}>
            Open Updates
          </button>
        </p>
      </>
    );
  return <SandboxPage backend={backend} />;
}

// While the add-on enrolls, a running setup says everything its status would.
const enrolling = ['waiting_for_approval', 'waitlisted', 'enrolling'];

function SandboxPage({ backend }: { backend: BackendState }) {
  const state = backend.state!;
  const sandbox = useResource<SandboxStatus>('sandbox', { refreshKey: state.resource_revision });
  useRereadAfterActions(state.operations, sandbox.refresh);
  // An ended setup stays on the page until it is dismissed, also across launches.
  const { dismissed, dismiss } = useDismissedOperation('darkbloom.sandbox.dismissed-setup');
  const setup = latestSetup(state.operations);
  const status = sandbox.data;
  const installed = isInstalled(status);
  const running = setup?.state === 'running' ? setup : undefined;
  const ended =
    setup && !running && setup.state !== 'succeeded' && setup.id !== dismissed ? setup : undefined;
  const consoleURL = installed && !status?.error ? status?.console_url : undefined;
  let content;
  if (!status)
    content = sandbox.loading ? (
      <p className={styles.note} role="status">
        Checking Darkbloom Sandbox…
      </p>
    ) : (
      <div className={styles.readFailure} role="alert">
        <span>{sandbox.error || 'Darkbloom Sandbox’s status is unavailable.'}</span>
        <Button onClick={() => void sandbox.refresh()}>Try again</Button>
      </div>
    );
  else if (installed)
    content =
      running && enrolling.includes(status.state) ? null : (
        <>
          <SandboxStatusCard status={status} backend={backend} refresh={sandbox.refresh} />
          {status.state === 'waitlisted' && supports(state, 'waitlists') && (
            <WaitlistCard feature="sandbox" backend={backend} compact />
          )}
        </>
      );
  else if (running) content = null;
  else if (justSetUp(state.operations))
    content = (
      <p className={styles.note} role="status">
        Checking Darkbloom Sandbox…
      </p>
    );
  else content = <NotInstalled backend={backend} />;
  return (
    <>
      <Header
        title={title}
        description={description}
        action={consoleURL ? <ConsoleButton url={consoleURL} backend={backend} /> : undefined}
      />
      {running && <SetupProgress operation={running} backend={backend} />}
      {ended && (
        <SetupProgress operation={ended} backend={backend} onDismiss={() => dismiss(ended.id)} />
      )}
      {status && sandbox.error && (
        <p className={styles.stale} role="status">
          Couldn’t refresh. Showing the last status.
        </p>
      )}
      {content}
    </>
  );
}

// The add-on's console lives on a Darkbloom host; the main process opens only those.
function ConsoleButton({ url, backend }: { url: string; backend: BackendState }) {
  return (
    <Button
      onClick={() =>
        void api
          ?.openApproval(url)
          .catch(() => backend.setError('Couldn’t open the Darkbloom Sandbox console.'))
      }
    >
      Open console <ArrowUpRight size={15} />
    </Button>
  );
}

// Reads the status again whenever a sandbox action finishes, here or elsewhere.
function useRereadAfterActions(operations: Operation[], refresh: () => Promise<void>) {
  const latest = operations.find((operation) => operation.action.startsWith('sandbox_'));
  const settled = latest && latest.state !== 'running' ? `${latest.id}:${latest.state}` : '';
  const seen = useRef(settled);
  useEffect(() => {
    if (settled === seen.current) return;
    seen.current = settled;
    if (settled) void refresh();
  }, [settled, refresh]);
}

// A setup that just succeeded installed the add-on, so a status that still says otherwise is
// from before it; the re-read follows within moments.
function justSetUp(operations: Operation[]) {
  const latest = operations.find((operation) => operation.action.startsWith('sandbox_'));
  return (
    latest?.action === 'sandbox_setup' &&
    latest.state === 'succeeded' &&
    Date.now() / 1000 - (latest.finished_at ?? 0) < 30
  );
}
