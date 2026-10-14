import { Pause, Play } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api, isPreview } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { Button, Header } from '../components/UI';
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
      ? 'Starting provider'
      : state.state === 'draining'
        ? 'Finishing requests'
        : null;
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
            {stoppable ? 'Stop provider' : (transition ?? 'Start providing')}
          </Button>
        }
      />
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
      />
      {(!state.linked || state.link) && (
        <footer className={styles.footer}>
          {!state.linked && (
            <button onClick={() => void backend.act({ action: 'link' })}>Link account</button>
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
