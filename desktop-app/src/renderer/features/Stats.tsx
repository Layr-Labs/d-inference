import { useMemo, useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { isPreview } from '../useBackend';
import { compact, gb } from '../format';
import { Button, External, Header } from '../components/UI';
import { LiveModels } from './insights/LiveModels';
import { TokenMilestones } from './insights/TokenMilestones';
import { useInsights } from './insights/useInsights';
import { previewStats } from '../previewStats';
import { observedTraffic } from './stats/data';
import { RequestFlow } from './stats/RequestFlow';
import { TrafficChart } from './stats/TrafficChart';
import styles from './stats/stats.module.css';
export function Stats({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const state = backend.state!,
    [metric, setMetric] = useState<'requests' | 'tokens'>('requests'),
    [model, setModel] = useState('all');
  const models = useMemo(() => (isPreview ? previewStats(Date.now() / 1000) : []), []);
  const points = isPreview
    ? model === 'all'
      ? models[0].points.map((p, i) => ({
          at: p.at,
          requests: models.reduce((n, m) => n + m.points[i].requests, 0),
          tokens: models.reduce((n, m) => n + m.points[i].tokens, 0),
        }))
      : models.find((m) => m.id === model)!.points
    : observedTraffic(state);
  const totalRequests = models.reduce((n, m) => n + m.requests, 0),
    totalTokens = models.reduce((n, m) => n + m.tokens, 0);
  const { data: insights } = useInsights(state);
  return (
    <div className={styles.stats}>
      <Header
        level={embedded ? 2 : 1}
        title="Stats"
        description="See the work your Mac is doing."
        action={
          <Button disabled={backend.busy} onClick={() => void backend.act({ action: 'diagnose' })}>
            <ShieldCheck size={15} />
            Run diagnostics
          </Button>
        }
      />
      {isPreview && (
        <div className={styles.preview}>Design preview · simulated traffic and performance</div>
      )}
      <div className={styles.metrics}>
        <div>
          <span>Requests served</span>
          <strong>{compact(isPreview ? totalRequests : state.activity.requests)}</strong>
          <small>{isPreview ? 'Past 24 hours' : 'This session'}</small>
        </div>
        <div>
          <span>Output tokens</span>
          <strong>{compact(isPreview ? totalTokens : state.activity.tokens)}</strong>
          <small>{isPreview ? 'Past 24 hours' : 'This session'}</small>
        </div>
        <div>
          <span>Success rate</span>
          <strong>{isPreview ? '99.8%' : '—'}</strong>
          <small>{isPreview ? 'Completed requests' : 'Awaiting outcome data'}</small>
        </div>
        <div>
          <span>Active model memory</span>
          <strong>{gb(state.memory.active_gb)}</strong>
          <small>of {gb(state.memory.total_gb)}</small>
        </div>
      </div>
      {isPreview ? <RequestFlow state={state} preview /> : <LiveModels state={state} />}
      <TrafficChart
        points={points}
        metric={metric}
        onMetric={setMetric}
        scope={
          isPreview
            ? `${model === 'all' ? 'All models' : models.find((m) => m.id === model)?.name} · Past 24 hours · 30-minute intervals`
            : 'Observed intervals · this session'
        }
      />
      <section className={styles.modelTraffic}>
        <div className={styles.sectionHead}>
          <h2>Which models get the work</h2>
          {models.length > 0 && (
            <button className="text-link" onClick={() => setModel('all')}>
              Show all
            </button>
          )}
        </div>
        {models.length ? (
          <>
            <div className={styles.shareBar}>
              {models.map((m, i) => (
                <span
                  key={m.id}
                  data-index={i}
                  style={{ width: `${(m.requests / totalRequests) * 100}%` }}
                />
              ))}
            </div>
            <div className={styles.tableHead}>
              <span>Model</span>
              <span>Requests</span>
              <span>Share</span>
              <span>Generation</span>
            </div>
            {models.map((m, i) => (
              <button
                key={m.id}
                className={styles.modelRow}
                aria-pressed={model === m.id}
                onClick={() => setModel(model === m.id ? 'all' : m.id)}
              >
                <strong>
                  <i data-index={i} />
                  {m.name}
                </strong>
                <span>{compact(m.requests)}</span>
                <span>{((m.requests / totalRequests) * 100).toFixed(0)}%</span>
                <span>
                  {m.speed} <small>tok/s</small>
                </span>
              </button>
            ))}
          </>
        ) : (
          <p className={styles.footnote}>
            Per-model traffic history is not yet available from the runtime.
          </p>
        )}
      </section>
      {insights && <TokenMilestones tokens={insights.lifetime.completion_tokens} />}
      <details className={styles.health}>
        <summary>Runtime & readiness</summary>
        <p>{state.readiness}</p>
        <p>
          Runtime {state.version} · Local API {state.endpoint ? 'available' : 'not enabled'}
        </p>
        <External target="docs">Troubleshooting guide</External>
      </details>
    </div>
  );
}
