import { useEffect, useState } from 'react';
import { Pause, Play } from 'lucide-react';
import { ParticleScene } from './ParticleScene';
import type { Snapshot } from '../../../shared/contracts';
import { modelName } from '../../models/facts';
import { useReducedMotion } from '../../useReducedMotion';
import { activityFresh } from './data';
import styles from './stats.module.css';
export function RequestFlow({
  state,
  preview,
  compact = false,
}: {
  state: Snapshot;
  preview: boolean;
  compact?: boolean;
}) {
  const [paused, setPaused] = useState(false);
  const reduced = useReducedMotion();
  const [now, setNow] = useState(Date.now() / 1000);
  const fresh = activityFresh(state, now);
  const animate =
    preview &&
    fresh &&
    !paused &&
    !reduced &&
    !!state.activity.models?.some(
      (model) => ['running', 'idle'].includes(model.state) && model.running > 0,
    );
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now() / 1000), 2000);
    return () => clearInterval(timer);
  }, []);
  const models = (state.activity.models || []).filter((model) =>
    ['running', 'idle'].includes(model.state),
  );
  const running = fresh ? models.reduce((sum, model) => sum + model.running, 0) : undefined;
  const waiting = fresh ? models.reduce((sum, model) => sum + model.waiting, 0) : undefined;
  return (
    <section
      className={styles.flow}
      data-animate={animate}
      data-compact={compact}
      aria-label="Requests moving through this Mac"
    >
      <div className={styles.sectionHead}>
        <div>
          <h2>Your Mac at work</h2>
          <span>
            {preview
              ? 'Simulated activity'
              : fresh
                ? 'Current runtime activity'
                : 'Waiting for current activity'}
          </span>
        </div>
        <button
          aria-label={paused ? 'Resume activity animation' : 'Pause activity animation'}
          onClick={() => setPaused(!paused)}
        >
          {paused ? <Play size={14} /> : <Pause size={14} />}
        </button>
      </div>
      <div className={styles.flowCounts}>
        <strong>{running ?? '—'}</strong>
        <span>in progress</span>
        <b>{waiting ?? '—'}</b>
        <span>waiting</span>
        <span className={styles.liveDot}>{fresh ? 'Connected' : 'Not live'}</span>
      </div>
      {preview && (
        <ParticleScene
          animate={animate}
          active={fresh && !!running}
          names={models.map((model) => modelName(state.models, model.model))}
        />
      )}
      {!preview && (
        <div className={styles.modelLanes}>
          {models.map((model, index) => {
            return (
              <div key={model.model}>
                <span className={styles.modelGlyph}>{index === 0 ? '◎' : '✧'}</span>
                <strong>{modelName(state.models, model.model)}</strong>
                <span className={styles.lane}>
                  <i
                    style={{
                      width: fresh
                        ? `${preview ? Math.min(100, model.running * 4) : model.running > 0 ? 100 : 0}%`
                        : '0%',
                    }}
                  />
                </span>
                <small>{!fresh ? 'Waiting' : `${model.running} running`}</small>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
