import { Pin } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { modelFacts, pinnedMemoryLine } from '../../models/facts';
import styles from './pinList.module.css';

export function PinList({
  snapshot,
  pinned,
  noun,
  onChange,
}: {
  snapshot: Snapshot;
  pinned: string[];
  noun: string;
  onChange: (pinned: string[]) => void;
}) {
  const toggle = (id: string) =>
    onChange(pinned.includes(id) ? pinned.filter((item) => item !== id) : [...pinned, id]);
  const summary = pinnedMemoryLine(snapshot, pinned, noun);
  return (
    <>
      <ul className={styles.pins}>
        {snapshot.models.map((model) => {
          const on = pinned.includes(model.id);
          return (
            <li key={model.id}>
              <label className={styles.pin} data-on={on} data-disabled={!model.eligible}>
                <input
                  type="checkbox"
                  checked={on}
                  disabled={!model.eligible}
                  onChange={() => toggle(model.id)}
                />
                <span className={styles.pinMark} aria-hidden>
                  <Pin size={13} />
                </span>
                <span className={styles.pinName}>
                  <strong>{model.display_name}</strong>
                  <small>{modelFacts(model)}</small>
                </span>
                {model.eligible && (
                  <span className={styles.badge} data-ready={model.downloaded}>
                    {model.downloaded ? 'On this Mac' : 'Downloads on start'}
                  </span>
                )}
              </label>
            </li>
          );
        })}
      </ul>
      {pinned.length > 0 && (
        <p className={styles.pinSummary} data-exceeds={summary.exceeds}>
          {summary.exceeds
            ? `${summary.text}. That’s more memory than this Mac has; choose fewer models.`
            : summary.text}
        </p>
      )}
    </>
  );
}
