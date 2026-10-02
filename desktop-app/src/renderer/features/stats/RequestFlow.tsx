import { useEffect, useState } from 'react';
import { ArrowDownToLine, BookOpen, Cpu, Send, Pause, Play } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { activityFresh } from './data';
import styles from './stats.module.css';
const stages = [
  { name: 'Receive', Icon: ArrowDownToLine },
  { name: 'Read', Icon: BookOpen },
  { name: 'Generate', Icon: Cpu },
  { name: 'Send', Icon: Send },
];
export function RequestFlow({
  state,
  preview,
  compact = false,
}: {
  state: Snapshot;
  preview: boolean;
  compact?: boolean;
}) {
  const [tick, setTick] = useState(0),
    [paused, setPaused] = useState(false),
    [reduced, setReduced] = useState(false);
  const [now, setNow] = useState(Date.now() / 1000);
  useEffect(() => {
    const query = window.matchMedia?.('(prefers-reduced-motion: reduce)');
    if (!query) return;
    const update = () => setReduced(query.matches);
    update();
    query.addEventListener('change', update);
    return () => query.removeEventListener('change', update);
  }, []);
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
  useEffect(() => {
    if (!animate) return;
    const timer = setInterval(() => setTick((value) => value + 1), 800);
    return () => clearInterval(timer);
  }, [animate]);
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
        <div className={styles.stages}>
          {stages.map(({ name, Icon }, i) => (
            <div
              key={name}
              className={styles.stage}
              data-active={fresh && !!running && Math.floor(tick / 2) % 4 === i}
            >
              <Icon size={19} />
              <span>{name}</span>
              {i < 3 && (
                <i className={styles.connector}>
                  <b />
                </i>
              )}
            </div>
          ))}
        </div>
      )}
      <div className={styles.modelLanes}>
        {models.map((model, index) => {
          const stage = (Math.floor(tick / 2) + index * 2) % 4;
          return (
            <div key={model.model}>
              <span className={styles.modelGlyph}>{index === 0 ? '◎' : '✧'}</span>
              <strong>
                {state.models.find((m) => m.id === model.model)?.display_name || model.model}
              </strong>
              <span className={styles.lane}>
                <i
                  style={{
                    width: fresh
                      ? `${preview ? 25 + stage * 23 : model.running > 0 ? 100 : 0}%`
                      : '0%',
                  }}
                />
              </span>
              <small>
                {!fresh ? 'Waiting' : preview ? stages[stage].name : `${model.running} running`}
              </small>
            </div>
          );
        })}
      </div>
    </section>
  );
}
