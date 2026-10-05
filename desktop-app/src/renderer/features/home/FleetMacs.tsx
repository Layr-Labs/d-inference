import { useState } from 'react';
import { Search } from 'lucide-react';
import type { Machine } from '../../../shared/contracts';
import { money } from '../../format';
import { Empty, Status } from '../../components/UI';
import { MachineIcon } from '../machines/MachineIcon';
import { isOnline, memoryLabel } from '../machines/fleet';
import styles from './fleet.module.css';

export function FleetMacs({
  machines,
  localID,
  onOpen,
  recent = false,
}: {
  machines: Machine[];
  localID: string;
  onOpen: (id: string) => void;
  recent?: boolean;
}) {
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState('all');
  const visible = machines.filter(
    (machine) =>
      `${machine.name} ${machine.chip}`.toLowerCase().includes(query.toLowerCase()) &&
      (filter === 'all' || (isOnline(machine.status) ? filter === 'online' : filter === 'offline')),
  );
  return (
    <section aria-label="Your Macs">
      <div className={styles.listHeading}>
        <h3>Your Macs</h3>
        <span>{machines.length} Macs</span>
      </div>
      <div className={styles.filters}>
        <label className="search">
          <Search size={15} />
          <input
            aria-label="Search Macs"
            placeholder="Search name or chip"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
        </label>
        <select
          aria-label="Filter Macs"
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        >
          <option value="all">All Macs</option>
          <option value="online">Online</option>
          <option value="offline">Not online</option>
        </select>
      </div>
      <div className={styles.table}>
        <div className={styles.tableLabels}>
          <span>Mac</span>
          <span>Status</span>
          <span>Models</span>
          <span>Usage earnings · {recent ? 'Recent' : '7d'}</span>
        </div>
        {visible.map((machine) => (
          <button
            key={machine.id}
            className={styles.tableRow}
            aria-label={`Open ${machine.name}`}
            onClick={() => onOpen(machine.id)}
          >
            <span className={styles.machineName}>
              <MachineIcon name={machine.name} size={22} />
              <span>
                <strong>{machine.name}</strong>
                <small>{machine.id === localID ? 'This Mac' : 'View only'}</small>
                <small>
                  {machine.chip} · {memoryLabel(machine)}
                </small>
              </span>
            </span>
            <Status state={isOnline(machine.status) ? 'online' : 'offline'}>
              {machine.status}
            </Status>
            <span>{machine.models.length}</span>
            <strong>{money(machine.earnings_micro_usd)}</strong>
          </button>
        ))}
      </div>
      {!visible.length && <Empty title="No matching Macs" />}
    </section>
  );
}
