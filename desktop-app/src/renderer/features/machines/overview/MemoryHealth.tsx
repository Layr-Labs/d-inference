import type { Snapshot } from '../../../../shared/contracts';
import { gb } from '../../../format';
import styles from './overview.module.css';

export function MemoryHealth({ memory }: { memory: Snapshot['memory'] }) {
  const { total_gb: total, active_gb: active, cache_gb: cache, free_for_load_gb: free } = memory;
  const share = (value = 0) => (total > 0 ? Math.min(100, Math.max(0, (value / total) * 100)) : 0);
  const activeShare = share(active);
  const reported = active != null || cache != null;
  // The runtime reports zero when it could not detect this Mac's memory.
  const size = total > 0 ? gb(total) : 'unknown';
  return (
    <div className={styles.cell}>
      <div className={styles.cellLabel}>
        <span>Memory</span>
        <span>
          {reported
            ? `${gb((active || 0) + (cache || 0))} of ${size}`
            : total > 0
              ? `${size} total`
              : 'Memory unknown'}
        </span>
      </div>
      <span className={styles.memoryBar} aria-hidden="true">
        <i data-segment="active" style={{ width: `${activeShare}%` }} />
        <i
          data-segment="cache"
          style={{ width: `${Math.min(share(cache), 100 - activeShare)}%` }}
        />
      </span>
      <small className={styles.legend}>
        {reported ? (
          <>
            {active != null && (
              <span>
                <i data-segment="active" />
                {gb(active)} active
              </span>
            )}
            {cache != null && (
              <span>
                <i data-segment="cache" />
                {gb(cache)} cache
              </span>
            )}
            {free != null && <span>{gb(free)} free to load</span>}
          </>
        ) : (
          'Reported while this Mac is serving.'
        )}
      </small>
    </div>
  );
}
