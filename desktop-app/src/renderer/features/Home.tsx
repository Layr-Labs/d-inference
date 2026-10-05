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
  const running = state.state === 'running';
  return (
    <div className={styles.dashboard}>
      <Header
        title="Your contribution"
        action={
          <Button
            disabled={backend.busy}
            onClick={() => (running ? void backend.act({ action: 'stop' }) : navigate('models'))}
          >
            {running ? <Pause size={14} /> : <Play size={14} />}{' '}
            {running ? 'Stop provider' : 'Start providing'}
          </Button>
        }
      />
      <NetworkMilestone network={backend.network} />
      <ContributionMetrics activity={state.activity} explore={() => navigate('analysis')} />
      <div className={styles.activity}>
        <ChipStage state={state} preview={isPreview} />
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
