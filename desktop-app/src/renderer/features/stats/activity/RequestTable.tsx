import type { RequestRecord } from '../../../../shared/contracts';
import { clockTime, count, money } from '../../../format';
import { duration, outcomes, tokensPerSecond } from './requests';
import styles from './activity.module.css';

export function RequestTable({
  records,
  names,
  now,
}: {
  records: RequestRecord[];
  names: Map<string, string>;
  now: number;
}) {
  return (
    <div className={styles.tableWrap}>
      <table className={styles.table}>
        <thead>
          <tr>
            <th scope="col">Time</th>
            <th scope="col">Model</th>
            <th scope="col" className={styles.number}>
              Input tokens
            </th>
            <th scope="col" className={styles.number}>
              Output tokens
            </th>
            <th scope="col" className={styles.number}>
              Duration
            </th>
            <th scope="col" className={styles.number}>
              Tokens/s
            </th>
            <th scope="col">Outcome</th>
            <th scope="col" className={styles.number}>
              Earned
            </th>
          </tr>
        </thead>
        <tbody>
          {records.map((record) => {
            const speed = tokensPerSecond(record);
            return (
              <tr key={record.id}>
                <td>{clockTime(record.started_at, now)}</td>
                <td>{names.get(record.model) || record.model}</td>
                <td className={styles.number}>{count(record.input_tokens)}</td>
                <td className={styles.number}>{count(record.output_tokens)}</td>
                <td className={styles.number}>{duration(record.duration_ms)}</td>
                <td className={styles.number}>{speed === undefined ? '—' : speed.toFixed(1)}</td>
                <td>
                  <span className={styles.outcome} data-outcome={record.outcome}>
                    {outcomes[record.outcome]}
                  </span>
                </td>
                <td className={styles.number}>
                  {record.earnings_micro_usd === undefined ? (
                    <span className={styles.pending}>Pending</span>
                  ) : (
                    money(record.earnings_micro_usd, 4)
                  )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
