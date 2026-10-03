import type { Machine } from '../../../shared/contracts';
import { MachineIcon } from './MachineIcon';
import { isOnline, memoryLabel } from './fleet';
import styles from './machines.module.css';
export function MachineRail({
  machines,
  selected,
  localID,
  onSelect,
}: {
  machines: Machine[];
  selected: string;
  localID: string;
  onSelect: (id: string) => void;
}) {
  return (
    <aside className={styles.rail} aria-label="Your Macs">
      <div className={styles.railTitle}>
        <span>My Macs</span>
        <span>{machines.length}</span>
      </div>
      <div className={styles.railItems}>
        {machines.map((machine) => {
          const local = machine.id === localID;
          return (
            <button
              key={machine.id}
              className={styles.railItem}
              aria-pressed={selected === machine.id}
              aria-label={`Select ${machine.name}, ${local ? 'This Mac' : 'View only'}`}
              onClick={() => onSelect(machine.id)}
            >
              <MachineIcon name={machine.name} size={21} />
              <span>
                <strong>{machine.name}</strong>
                <small>
                  {local ? 'This Mac' : 'View only'} · {memoryLabel(machine)}
                </small>
                <small>
                  <i data-online={isOnline(machine.status)} />
                  {machine.status}
                </small>
              </span>
            </button>
          );
        })}
      </div>
    </aside>
  );
}
