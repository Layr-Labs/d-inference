import { ArrowUpRight, Pause, Play } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api, isPreview } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { compact, money } from '../format';
import { Button, Header } from '../components/UI';
import { RequestFlow } from './stats/RequestFlow';
import styles from './home/home.module.css';

export function Home({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
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
      <section className={styles.contribution}>
        <div className={styles.shared}>
          <span>Tokens shared this session</span>
          <strong>
            {state.activity.tokens ? BigInt(state.activity.tokens).toLocaleString('en-US') : '—'}
          </strong>
          <small>
            {state.activity.requests
              ? BigInt(state.activity.requests).toLocaleString('en-US')
              : '—'}{' '}
            requests served{' '}
            <button onClick={() => navigate('analysis')}>
              Explore Stats <ArrowUpRight size={12} />
            </button>
          </small>
        </div>
        <div className={styles.collective}>
          <div className={styles.constellation} aria-hidden="true">
            {Array.from({ length: 45 }, (_, i) => (
              <i
                key={i}
                data-lit={i % 7 === 0 || i % 11 === 0}
                style={{ animationDelay: `${i * 90}ms` }}
              />
            ))}
          </div>
          <div>
            <strong>{compact(backend.network?.total_macs)}</strong>
            <span>Macs powering the network</span>
            <small>{compact(backend.network?.total_tokens)} tokens shared together</small>
          </div>
        </div>
      </section>
      <div className={styles.activity}>
        <RequestFlow state={state} preview={isPreview} compact />
      </div>
      <footer className={styles.footer}>
        <span>{isPreview ? 'Simulated activity' : state.readiness}</span>
        <span>
          Past 7 days <b>{money(backend.cloud?.week_micro_usd)}</b>
          <button onClick={() => navigate('earnings')}>
            View earnings <ArrowUpRight size={12} />
          </button>
        </span>
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
