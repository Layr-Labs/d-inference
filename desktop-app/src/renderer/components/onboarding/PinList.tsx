import { Pin } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { modelFacts, pinnedMemoryLine } from '../../models/facts';
import { servesNetwork } from '../../models/selection';
import styles from './pinList.module.css';

export function PinList({
  snapshot,
  pinned,
  noun,
  network,
  onChange,
}: {
  snapshot: Snapshot;
  pinned: string[];
  noun: string;
  // Serving the network, where only catalog models can be pinned.
  network: boolean;
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
          const usable = network ? servesNetwork(model) : model.eligible;
          return (
            <li key={model.id}>
              <label className={styles.pin} data-on={on} data-disabled={!usable}>
                <input
                  type="checkbox"
                  checked={on}
                  disabled={!usable}
                  onChange={() => toggle(model.id)}
                />
                <span className={styles.pinMark} aria-hidden>
                  <Pin size={13} />
                </span>
                <span className={styles.pinName}>
                  <strong>{model.display_name}</strong>
                  <small>{modelFacts(model, network)}</small>
                </span>
                {usable && (
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
          {summary.limit === 'memory'
            ? `${summary.text}. That’s more memory than this Mac has; choose fewer models.`
            : summary.limit === 'slots'
              ? `${summary.text}. That’s more models than this Mac keeps in memory at once; choose fewer models.`
              : summary.text}
        </p>
      )}
    </>
  );
}
