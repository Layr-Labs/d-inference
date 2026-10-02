import { Grid2X2, Laptop, Monitor } from 'lucide-react';
import type { Machine } from '../../../shared/contracts';
import styles from './machines.module.css';
export function MachineRail({
  machines,
  selected,
  localID,
  onSelect,
}: {
  machines: Machine[];
  selected: string | null;
  localID: string;
  onSelect: (id: string | null) => void;
}) {
  return (
    <aside className={styles.rail} aria-label="Your Macs">
      <div className={styles.railTitle}>
        <span>My Macs</span>
        <span>{machines.length}</span>
      </div>
      <div className={styles.railItems}>
        <button className={styles.railItem} aria-pressed={!selected} onClick={() => onSelect(null)}>
          <Grid2X2 size={18} />
          <strong>Fleet overview</strong>
        </button>
        {machines.map((machine) => {
          const Icon = machine.name.includes('Book') ? Laptop : Monitor;
          const local = machine.id === localID;
          return (
            <button
              key={machine.id}
              className={styles.railItem}
              aria-pressed={selected === machine.id}
              aria-label={`Select ${machine.name}, ${local ? 'This Mac' : 'View only'}`}
              onClick={() => onSelect(machine.id)}
            >
              <Icon size={21} />
              <span>
                <strong>{machine.name}</strong>
                <small>
                  {local ? 'This Mac' : 'View only'} ·{' '}
                  {machine.memory_gb ? `${machine.memory_gb} GB` : 'Memory unknown'}
                </small>
                <small>
                  <i data-online={['running', 'online', 'serving'].includes(machine.status)} />
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
