import { Pause, Play } from 'lucide-react';
import { useState } from 'react';
import type { BackendState } from '../useBackend';
import { api, isPreview } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { supportsNewProviders } from '../../shared/macos';
import { Button, Header, Notice } from '../components/UI';
import { openSoftwareUpdate } from '../softwareUpdate';
import { updateMacOSDetail } from './machines/overview/readinessSteps';
import { ContributionMetrics } from './home/ContributionMetrics';
import { ChipStage } from './home/chip/ChipStage';
import { FleetSummary } from './home/FleetSummary';
import { NetworkMilestone } from './home/NetworkMilestone';
import styles from './home/home.module.css';

export function Home({
  backend,
  navigate,
  openMachine,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
  openMachine: (id: string) => void;
}) {
  const state = backend.state!;
  // A stale provider is still running, so it can be stopped; starting and draining are
  // transitions to wait out rather than prompts to start again.
  const stoppable = state.state === 'running' || state.state === 'stale';
  const transition =
    state.state === 'starting'
      ? 'Starting…'
      : state.state === 'draining'
        ? 'Finishing requests'
        : null;
  const [macosPrompt, dismissMacOSPrompt] = useMacOSPrompt();
  const outdated = !supportsNewProviders(backend.system?.macosVersion);
  return (
    <div className={styles.dashboard}>
      <Header
        title="Your contribution"
        action={
          <Button
            disabled={backend.busy || transition !== null}
            onClick={() => (stoppable ? void backend.act({ action: 'stop' }) : navigate('models'))}
          >
            {stoppable ? <Pause size={14} /> : <Play size={14} />}{' '}
            {stoppable ? 'Stop serving' : (transition ?? 'Start serving')}
          </Button>
        }
      />
      {outdated && macosPrompt && (
        <Notice onClose={dismissMacOSPrompt}>
          {updateMacOSDetail}
          <Button onClick={openSoftwareUpdate}>Open Software Update</Button>
        </Notice>
      )}
      <NetworkMilestone network={backend.network} />
      <ContributionMetrics activity={state.activity} explore={() => navigate('analysis')} />
      <div className={styles.activity}>
        <ChipStage
          state={state}
          preview={isPreview}
          cooling={backend.cooling}
          onCooling={() => navigate('cooling')}
        />
      </div>
      <FleetSummary
        backend={backend}
        openMachine={openMachine}
        onEarnings={() => navigate('earnings')}
        onStart={() => navigate('models')}
      />
      {(!state.linked || state.link) && (
        <footer className={styles.footer}>
          {/* Once a link code exists the next step is the code itself, not another request. */}
          {!state.linked && !state.link && (
            <button
              disabled={
                backend.busy ||
                state.operations.some(
                  (operation) => operation.action === 'link' && operation.state === 'running',
                )
              }
              onClick={() => void backend.act({ action: 'link' })}
            >
              Link account
            </button>
          )}
          {state.link && (
            <button onClick={() => void api?.openExternal('link')}>
              Link code: {state.link.code}
            </button>
          )}
        </footer>
      )}
    </div>
  );
}

// Dismissing the macOS prompt hides it until Darkbloom is next opened; This Mac's next steps
// keep it in view meanwhile.
const dismissedKey = 'darkbloom.macos-prompt-dismissed';
function useMacOSPrompt(): [boolean, () => void] {
  const [shown, setShown] = useState(() => {
    try {
      return sessionStorage.getItem(dismissedKey) !== '1';
    } catch {
      return true;
    }
  });
  const dismiss = () => {
    setShown(false);
    try {
      sessionStorage.setItem(dismissedKey, '1');
    } catch {
      // Without storage it is dismissed until Home is next shown.
    }
  };
  return [shown, dismiss];
}
