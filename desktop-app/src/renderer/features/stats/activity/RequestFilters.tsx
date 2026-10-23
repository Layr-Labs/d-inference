import type { RequestRecord } from '../../../../shared/contracts';
import { compact, count, money } from '../../../format';
import { outcomes, settledEarnings, type Outcome, type RequestFilter } from './requests';
import styles from './activity.module.css';

export function RequestFilters({
  filter,
  onChange,
  models,
  names,
  records,
}: {
  filter: RequestFilter;
  onChange: (next: Partial<RequestFilter>) => void;
  models: string[];
  names: Map<string, string>;
  records: RequestRecord[];
}) {
  const earned = settledEarnings(records);
  const tokens = records.reduce((sum, record) => sum + record.output_tokens, 0);
  return (
    <div className={styles.toolbar}>
      <select
        aria-label="Filter by model"
        value={filter.model}
        onChange={(event) => onChange({ model: event.target.value })}
      >
        <option value="all">All models</option>
        {models.map((id) => (
          <option key={id} value={id}>
            {names.get(id) || id}
          </option>
        ))}
      </select>
      <select
        aria-label="Filter by outcome"
        value={filter.outcome}
        onChange={(event) => onChange({ outcome: event.target.value as Outcome | 'all' })}
      >
        <option value="all">All outcomes</option>
        {Object.entries(outcomes).map(([id, label]) => (
          <option key={id} value={id}>
            {label}
          </option>
        ))}
      </select>
      <span>
        {count(records.length)} requests · {compact(tokens)} output tokens ·{' '}
        {money(earned.toString(), earned < 1_000_000n ? 4 : 2)} earned
      </span>
    </div>
  );
}
