import { useEffect, useState } from 'react';
import { Activity, Pause, Play } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import styles from './insights.module.css';

const serving = (state: string) => state === 'running' || state === 'idle';

export function LiveModels({ state }: { state: Snapshot }) {
  const [now, setNow] = useState(() => Date.now() / 1000);
  const [motion, setMotion] = useState(true);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now() / 1000), 2000);
    return () => clearInterval(timer);
  }, []);
  const stale =
    !['running', 'draining'].includes(state.state) ||
    !state.activity.sampled_at ||
    now - state.activity.sampled_at > 10 ||
    now - state.observed_at > 10 ||
    !state.activity.models;
  const models = state.activity.models || [];
  const running = models.reduce(
    (sum, model) => sum + (serving(model.state) ? model.running : 0),
    0,
  );
  return (
    <section
      className={styles.live}
      aria-labelledby="live-models-title"
      data-animate={motion && !stale}
    >
      <div className={styles.sectionHead}>
        <div>
          <div className={styles.eyeline}>
            <Activity size={16} />
            <span>{stale ? 'Waiting for activity' : 'Live on this Mac'}</span>
          </div>
          <h2 id="live-models-title">Models at work</h2>
        </div>
        <button
          type="button"
          className={styles.motionButton}
          onClick={() => setMotion(!motion)}
          aria-label={motion ? 'Pause activity animation' : 'Resume activity animation'}
        >
          {motion ? <Pause size={14} /> : <Play size={14} />}{' '}
          {motion ? 'Pause motion' : 'Resume motion'}
        </button>
      </div>
      <div className={styles.liveSummary}>
        <strong>{stale ? '—' : running}</strong>
        <span>
          requests running
          <br />
          <span className="muted">Native activity · refreshes every 2 seconds</span>
        </span>
      </div>
      <div className={styles.lanes}>
        {models.map((model) => (
          <div className={styles.lane} key={model.model}>
            <div className={styles.liveRow}>
              <span className={styles.modelName}>
                <span className={styles.modelMark}>
                  {(
                    state.models.find((m) => m.id === model.model)?.display_name || model.model
                  ).slice(0, 1)}
                </span>
                <span>
                  {state.models.find((m) => m.id === model.model)?.display_name || model.model}
                  <small>
                    {model.state} · {stale ? '—' : model.waiting} waiting
                  </small>
                </span>
              </span>
              <span className={styles.activityCells} aria-hidden="true">
                {Array.from({ length: 24 }, (_, i) => (
                  <i
                    key={i}
                    data-active={!stale && serving(model.state) && i < model.running}
                    style={{ animationDelay: `${i * 65}ms` }}
                  />
                ))}
              </span>
              <span className={styles.running}>
                {stale
                  ? 'Not current'
                  : serving(model.state)
                    ? `${model.running} running`
                    : model.state}
              </span>
            </div>
          </div>
        ))}
      </div>
      {models.length === 0 && (
        <p className={styles.empty}>
          {state.state === 'stopped'
            ? 'Start providing to see your models working.'
            : stale
              ? 'Waiting for the runtime to report model activity.'
              : 'No models are currently loaded.'}
        </p>
      )}
      <p className={styles.note}>
        {stale
          ? 'Activity is not current. Last reported counts are hidden.'
          : 'Each lit cell represents a running request, up to 24 per model.'}{' '}
        Request content stays private.
      </p>
    </section>
  );
}
