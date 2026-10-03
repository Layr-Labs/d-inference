import { ArrowUpRight, Pause, Play } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api, isPreview } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { count } from '../format';
import { Button, Header } from '../components/UI';
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
        description="Your Mac. Part of something bigger."
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
      <section className={styles.contribution}>
        <div className={styles.shared}>
          <span>Tokens shared this session</span>
          <strong>{count(state.activity.tokens)}</strong>
          <small>
            {count(state.activity.requests)} requests served{' '}
            <button onClick={() => navigate('analysis')}>
              Explore Stats <ArrowUpRight size={12} />
            </button>
          </small>
        </div>
      </section>
      <div className={styles.activity}>
        <ChipStage state={state} preview={isPreview} />
      </div>
      <FleetSummary
        backend={backend}
        openMachine={openMachine}
        onEarnings={() => navigate('earnings')}
      />
      <footer className={styles.footer}>
        <span>{isPreview ? 'Simulated activity' : state.readiness}</span>
        {!state.linked && (
          <button onClick={() => void backend.act({ action: 'link' })}>Link account</button>
        )}
        {state.link && (
          <button onClick={() => void api?.openExternal('link')}>
            Link code: {state.link.code}
          </button>
        )}
      </footer>
    </div>
  );
}
