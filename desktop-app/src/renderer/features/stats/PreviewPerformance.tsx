import { useMemo, useState } from 'react';
import type { BackendState } from '../../useBackend';
import { isPreview } from '../../useBackend';
import { compact, gb } from '../../format';
import { External } from '../../components/UI';
import { LiveModels } from '../insights/LiveModels';
import { previewStats } from '../../previewStats';
import { observedTraffic } from './data';
import { RequestFlow } from './RequestFlow';
import { TrafficChart, type TrafficMetric } from './TrafficChart';
import styles from './stats.module.css';

export function PreviewPerformance({ backend }: { backend: BackendState }) {
  const state = backend.state!,
    [metric, setMetric] = useState<TrafficMetric>('requests'),
    [model, setModel] = useState('all');
  const models = useMemo(() => (isPreview ? previewStats(Date.now() / 1000) : []), []);
  const points = isPreview
    ? model === 'all'
      ? models[0].points.map((p, i) => ({
          at: p.at,
          requests: models.reduce((n, m) => n + m.points[i].requests, 0),
          tokens: models.reduce((n, m) => n + m.points[i].tokens, 0),
          input: models.reduce((n, m) => n + (m.points[i].input ?? 0), 0),
          cached: models.reduce((n, m) => n + (m.points[i].cached ?? 0), 0),
        }))
      : models.find((m) => m.id === model)!.points
    : observedTraffic(state);
  const totalRequests = models.reduce((n, m) => n + m.requests, 0),
    totalTokens = models.reduce((n, m) => n + m.tokens, 0);
  return (
    <>
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
      <section>
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
      <details className={styles.health}>
        <summary>Runtime & readiness</summary>
        <p>{state.readiness}</p>
        <p>
          Runtime {state.version} · Local API {state.endpoint ? 'available' : 'not enabled'}
        </p>
        <External target="docs">Troubleshooting guide</External>
      </details>
    </>
  );
}
