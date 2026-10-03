import styles from './chip.module.css';

type Phase = 'prefill' | 'decode' | 'kv' | 'traffic' | 'neural';
const ITEMS: { id: Phase; label: string; note: string }[] = [
  { id: 'prefill', label: 'Prefill', note: 'Prompts processed in parallel on the GPU' },
  { id: 'decode', label: 'Decode', note: 'Every token streams the weights from memory' },
  { id: 'kv', label: 'KV cache', note: 'Context held in unified memory' },
  {
    id: 'traffic',
    label: 'Memory traffic',
    note: 'DRAM bandwidth through the system cache, not cache hits',
  },
  { id: 'neural', label: 'Neural Engine', note: 'Idle: Darkbloom runs on the GPU' },
];
/** Below this the Neural Engine reads as idle. */
const NEURAL_ACTIVE = 0.02;

/** Distinct shapes per phase, so the legend never relies on colour alone. */
function Glyph({ phase }: { phase: Phase }) {
  return (
    <svg className={styles.glyph} viewBox="0 0 14 14" aria-hidden="true">
      {phase === 'prefill' &&
        [1, 8].flatMap((x) =>
          [1, 8].map((y) => <rect key={`${x}${y}`} x={x} y={y} width="5" height="5" rx="1" />),
        )}
      {phase === 'decode' && (
        <>
          <rect x="1" y="1" width="12" height="12" rx="2" fill="none" strokeWidth="1.2" />
          <rect x="5.5" y="1" width="3" height="12" />
        </>
      )}
      {phase === 'kv' &&
        [1, 5.5, 10].map((y, i) => (
          <rect key={y} x="1" y={y} width={12 - i * 4} height="3" rx="0.8" />
        ))}
      {phase === 'traffic' &&
        [2, 7, 12].map((y) => (
          <path key={y} d={`M1 ${y}h8`} fill="none" strokeWidth="1.4" strokeLinecap="round" />
        ))}
      {phase === 'traffic' &&
        [2, 7, 12].map((y) => <circle key={`dot${y}`} cx="11.5" cy={y} r="1.5" />)}
      {phase === 'neural' && (
        <rect
          x="1.5"
          y="1.5"
          width="11"
          height="11"
          rx="2"
          fill="none"
          strokeWidth="1.2"
          strokeDasharray="2 2"
        />
      )}
    </svg>
  );
}

export function PhaseLegend({ levels }: { levels: Record<Phase, number> }) {
  const neuralIdle = levels.neural < NEURAL_ACTIVE;
  return (
    <ul className={styles.legend} aria-label="What lights up">
      {ITEMS.map(({ id, label, note }) => (
        <li key={id} data-phase={id}>
          <Glyph phase={id} />
          <span className={styles.legendText}>
            <b>{label}</b>
            <small>{id === 'neural' && !neuralIdle ? 'In use by another app' : note}</small>
          </span>
          {id === 'neural' && neuralIdle ? (
            <em className={styles.idle}>Idle</em>
          ) : (
            <span className={styles.meter} aria-hidden="true">
              <i style={{ transform: `scaleX(${levels[id]})` }} />
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}
