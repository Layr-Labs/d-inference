import type { ReadinessTone } from './readiness';
import styles from './overview.module.css';

export function ReadinessHealth({
  tone,
  status,
  summary,
}: {
  tone: ReadinessTone;
  status: string;
  summary: string;
}) {
  return (
    <div className={styles.cell}>
      <div className={styles.cellLabel}>
        <span>Readiness</span>
      </div>
      <strong role="status">
        <i className={styles.tone} data-tone={tone} aria-hidden="true" />
        {status}
      </strong>
      <small>{summary}</small>
    </div>
  );
}
