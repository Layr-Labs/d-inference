import { ArrowRight, ArrowUpRight, Cpu, Pause, Play } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { compact, gb, money } from '../format';
import { Button, External, Header, Status } from '../components/UI';
import { LiveModels } from './insights/LiveModels';
import { Contribution } from './insights/Contribution';
import styles from './insights/insights.module.css';

export function ActivityChart({ backend }: { backend: BackendState }) {
  const samples = backend.state?.activity.samples || [];
  const deltas = samples.slice(1).map((s, i) => Math.max(0, s.requests - samples[i].requests));
  const max = Math.max(1, ...deltas);
  return (
    <div className="activity-chart" aria-label="Requests per observed interval">
      {deltas.length ? (
        deltas.map((n, i) => (
          <div className="activity-column" key={i} title={`${n} requests`}>
            <span style={{ height: `${Math.max(3, (n / max) * 100)}%` }} />
          </div>
        ))
      ) : (
        <p>Activity will appear as this Mac serves requests.</p>
      )}
    </div>
  );
}
export function Home({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  const active = state.state === 'running';
  const loaded = state.models.filter((model) => model.loaded);
  return (
    <>
      <Header
        title="Your contribution"
        description="A view of your Mac and the network it powers."
        action={
          <Button
            variant={active ? 'secondary' : 'primary'}
            disabled={backend.busy}
            onClick={() => (active ? void backend.act({ action: 'stop' }) : navigate('models'))}
          >
            {active ? <Pause size={15} /> : <Play size={15} />}{' '}
            {active ? 'Stop provider' : 'Start providing'}
          </Button>
        }
      />
      <div className="home-lead">
        <section className="earnings-lead">
          <span className="muted">Earned over the last 7 days</span>
          <div className="large-number">{money(backend.cloud?.week_micro_usd)}</div>
          <div className="lead-foot">
            <span>
              {money(backend.cloud?.lifetime_micro_usd)} <span className="muted">all time</span>
            </span>
            <button className="text-link" onClick={() => navigate('earnings')}>
              View earnings
            </button>
          </div>
          {backend.cloud?.error && <small>{backend.cloud.error}</small>}
          {!state.linked && (
            <Button onClick={() => void backend.act({ action: 'link' })}>
              Link your account <ArrowUpRight size={15} />
            </Button>
          )}
        </section>
        <section className="network-lead">
          <div className="network-visual" aria-hidden="true">
            {Array.from({ length: 84 }, (_, i) => (
              <i key={i} className={(i * 17 + (i % 5)) % 7 < 3 ? 'lit' : ''} />
            ))}
          </div>
          <div>
            <span className="muted">A network of people</span>
            <strong>
              {compact(backend.network?.total_macs)} <span>Macs connected</span>
            </strong>
            <small>{compact(backend.network?.total_tokens)} tokens processed</small>
          </div>
        </section>
      </div>
      <div className={styles.experience}>
        <LiveModels state={state} />
        <Contribution state={state} onEarnings={() => navigate('earnings')} />
      </div>
      <section className="section">
        <div className="section-title">
          <h2>This Mac</h2>
          <button className="text-link" onClick={() => navigate('machines')}>
            Manage Macs <ArrowRight size={16} />
          </button>
        </div>
        <div className="machine-overview">
          <div className="machine-art">
            <Cpu size={44} strokeWidth={1} />
          </div>
          <div className="machine-summary">
            <h3>
              {state.machine.name}
              <span className="tag">This Mac</span>
            </h3>
            <p>
              {state.machine.chip} · {state.machine.memory_gb} GB
            </p>
            <Status state={active ? 'online' : 'offline'}>
              {active
                ? state.readiness
                : state.state === 'draining'
                  ? 'Finishing accepted requests'
                  : 'Provider stopped'}
            </Status>
          </div>
          <div className="machine-load">
            <span className="muted">In memory</span>
            <strong>
              {loaded.length} model{loaded.length === 1 ? '' : 's'}
            </strong>
            <small>
              {loaded.map((model) => model.display_name).join(', ') || 'No models loaded'}
            </small>
          </div>
        </div>
      </section>
      <section className="section">
        <div className="section-title">
          <div>
            <h2>Request activity</h2>
            <p>Observed intervals on this Mac</p>
          </div>
          <div className="inline-stats">
            <span>
              <strong>{compact(state.activity.requests)}</strong> requests
            </span>
            <span>
              <strong>{compact(state.activity.tokens)}</strong> tokens
            </span>
          </div>
        </div>
        <ActivityChart backend={backend} />
        <div className="chart-axis">
          <span>Earlier</span>
          <span>Now</span>
        </div>
      </section>
      <div className="split-bottom">
        <section>
          <h2>Memory</h2>
          <div className="memory-title">
            <strong>{gb(state.memory.active_gb)}</strong>
            <span>of {gb(state.memory.total_gb)}</span>
          </div>
          <div className="memory-track">
            <span
              style={{
                width: `${Math.min(100, ((state.memory.active_gb || 0) / (state.memory.total_gb || 1)) * 100)}%`,
              }}
            />
          </div>
          <p>Model memory is managed by the native runtime.</p>
        </section>
        <section>
          <h2>Build the grid with us</h2>
          <p>Follow updates, share feedback, and meet the people behind the network.</p>
          <External target="community">Provider community</External>
        </section>
      </div>
      {state.link && (
        <div className="link-code">
          <span>Enter this code to link your Mac</span>
          <strong>{state.link.code}</strong>
          <Button variant="primary" onClick={() => void api?.openExternal('link')}>
            Open browser <ArrowUpRight size={15} />
          </Button>
        </div>
      )}
    </>
  );
}
