import type { MemoryMap } from './memoryMap';
import { modelCSS } from './memoryStyle';
import styles from './memoryLegend.module.css';

const amount = (value: number | null, estimated = false) =>
  value === null ? '—' : `${estimated ? '~' : ''}${value.toFixed(1)} GB`;
export function MemoryLegend({
  memory,
  providerGb,
  otherGb,
}: {
  memory: MemoryMap;
  providerGb: number | null;
  otherGb: number | null;
}) {
  const total = memory.totalGb || 1;
  const weights = memory.segments.filter((s) => s.kind === 'weights');
  const weightShare = weights.reduce((sum, s) => sum + s.to - s.from, 0);
  const providerShare = Math.min(1, Math.max(weightShare, (providerGb ?? 0) / total));
  const otherShare = Math.min(1 - providerShare, (otherGb ?? 0) / total);
  const shared = providerGb === null ? null : Math.max(0, providerGb - memory.weightsGb);
  const free =
    providerGb !== null && otherGb !== null
      ? Math.max(0, memory.totalGb - providerGb - otherGb)
      : null;
  return (
    <section className={styles.memory} aria-label="Unified memory allocation">
      <div className={styles.heading}>
        <h3>Unified memory</h3>
        <span>{memory.totalGb} GB</span>
      </div>
      <div className={styles.total}>
        <span>Darkbloom</span>
        <strong>{amount(providerGb)}</strong>
      </div>
      <div className={styles.bar} aria-hidden="true">
        {weights.map((s) => (
          <i
            key={s.model}
            style={{ width: `${(s.to - s.from) * 100}%`, background: modelCSS(s.model) }}
          />
        ))}
        <i
          style={{
            width: `${Math.max(0, providerShare - weightShare) * 100}%`,
            background: 'var(--chip-kv)',
          }}
        />
        <i className={styles.other} style={{ width: `${otherShare * 100}%` }} />
      </div>
      <ul aria-label="Memory by model and system">
        {memory.models.map((model, i) => (
          <li key={model.id} title="Estimated model footprint">
            <i style={{ background: modelCSS(i) }} />
            <span>{model.name}</span>
            <b>{amount(model.gb > 0 ? model.gb : null, true)}</b>
          </li>
        ))}
        {shared !== null && shared > 0.1 && (
          <li title="Estimated allocator usage beyond model footprints">
            <i style={{ background: 'var(--chip-kv)' }} />
            <span>Shared KV / cache</span>
            <b>{amount(shared, true)}</b>
          </li>
        )}
        <li className={styles.system}>
          <i className={styles.other} />
          <span>Other apps + macOS</span>
          <b>{amount(otherGb, true)}</b>
        </li>
        <li>
          <i className={styles.free} />
          <span>Free</span>
          <b>{amount(free, true)}</b>
        </li>
      </ul>
    </section>
  );
}
