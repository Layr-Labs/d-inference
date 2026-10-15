import styles from './chip.module.css';

type Phase = 'prefill' | 'decode' | 'kv';
const ITEMS: { id: Phase; label: string }[] = [
  { id: 'prefill', label: 'Prefill' },
  { id: 'decode', label: 'Decode' },
  { id: 'kv', label: 'KV cache' },
];

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
    </svg>
  );
}

export function PhaseLegend({ levels }: { levels: Record<Phase, number> }) {
  return (
    <ul className={styles.legend} aria-label="What lights up">
      {ITEMS.map(({ id, label }) => (
        <li key={id} data-phase={id}>
          <Glyph phase={id} />
          <span className={styles.legendText}>
            <b>{label}</b>
          </span>
          <span className={styles.meter} aria-hidden="true">
            <i style={{ transform: `scaleX(${levels[id]})` }} />
          </span>
        </li>
      ))}
    </ul>
  );
}
