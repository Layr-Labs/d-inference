import type { Machine, Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { age, compact, gb, money } from '../../format';
import { ActivityChart } from '../../components/ActivityChart';
import styles from './machines.module.css';
export function MachineOverview({
  machine,
  local,
  backend,
  navigate,
}: {
  machine: Machine;
  local: boolean;
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  const names = machine.models.map(
    (id) => state.models.find((model) => model.id === id)?.display_name || id,
  );
  return (
    <>
      <div className={styles.readiness}>
        <i data-online={['running', 'online', 'serving'].includes(machine.status)} />
        <span>{local ? state.readiness : machine.status}</span>
        {!local && <small>Last observed {age(machine.observed_at).toLowerCase()}</small>}
      </div>
      {!local && <p className={styles.caption}>View only · Status and earnings only.</p>}
      <div className={styles.metrics}>
        <div>
          <span>Usage earnings · 7 days</span>
          <strong>{money(machine.earnings_micro_usd)}</strong>
        </div>
        <div>
          <span>Serving models</span>
          <strong>{machine.models.length}</strong>
        </div>
        <div>
          <span>Provider version</span>
          <strong>{machine.version || (local ? state.version : '—')}</strong>
        </div>
      </div>
      <section className={styles.section}>
        <div className={styles.tableHeading}>
          <h2>Serving models</h2>
          {local && (
            <button className="text-link" onClick={() => navigate('models')}>
              Manage models
            </button>
          )}
        </div>
        <div className={styles.modelNames}>
          {names.length ? (
            names.map((name) => <span key={name}>{name}</span>)
          ) : (
            <span>No serving models reported</span>
          )}
        </div>
      </section>
      {local && (
        <>
          <section className={styles.section}>
            <div className={styles.tableHeading}>
              <h2>Request activity</h2>
              <span>
                {compact(state.activity.requests)} requests · {compact(state.activity.tokens)}{' '}
                tokens
              </span>
            </div>
            <ActivityChart backend={backend} />
            <p className={styles.caption}>Observed intervals on this Mac.</p>
          </section>
          <section className={styles.section}>
            <div className={styles.tableHeading}>
              <h2>Model memory</h2>
              <span>
                {gb(state.memory.active_gb)} / {gb(state.memory.total_gb)}
              </span>
            </div>
            <div className="memory-track">
              <span
                style={{
                  width: `${Math.max(0, Math.min(100, ((state.memory.active_gb || 0) / (state.memory.total_gb || 1)) * 100))}%`,
                }}
              />
            </div>
          </section>
        </>
      )}
    </>
  );
}
