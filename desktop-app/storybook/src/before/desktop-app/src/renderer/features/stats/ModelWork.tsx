import { useMemo } from 'react';
import type { NativeModel, RequestRecord } from '../../../shared/contracts';
import { count, money } from '../../format';
import styles from './stats.module.css';

export function ModelWork({
  records,
  models,
}: {
  records: RequestRecord[];
  models: NativeModel[];
}) {
  const rows = useMemo(() => {
    const values = new Map<
      string,
      { id: string; requests: bigint; input: bigint; output: bigint; money: bigint }
    >();
    for (const record of records) {
      const row = values.get(record.model) ?? {
        id: record.model,
        requests: 0n,
        input: 0n,
        output: 0n,
        money: 0n,
      };
      row.requests++;
      row.input += BigInt(record.input_tokens);
      row.output += BigInt(record.output_tokens);
      row.money += BigInt(record.earnings_micro_usd ?? 0);
      values.set(record.model, row);
    }
    return [...values.values()].sort((a, b) =>
      a.money === b.money ? a.id.localeCompare(b.id) : a.money > b.money ? -1 : 1,
    );
  }, [records]);
  const names = new Map(models.map((model) => [model.id, model.display_name]));
  if (!rows.length) return null;
  return (
    <section>
      <div className={styles.sectionHead}>
        <h2>Model activity</h2>
        <span>Recorded history · this Mac</span>
      </div>
      <div className={styles.tableHead}>
        <span>Model</span>
        <span>Requests</span>
        <span>Input / output tokens</span>
        <span>Earned</span>
      </div>
      {rows.map((row) => (
        <div key={row.id} className={styles.modelRow}>
          <strong>{names.get(row.id) ?? row.id}</strong>
          <span>{count(row.requests)}</span>
          <span>
            {count(row.input)} / {count(row.output)}
          </span>
          <span>{money(row.money.toString(), 4)}</span>
        </div>
      ))}
    </section>
  );
}
