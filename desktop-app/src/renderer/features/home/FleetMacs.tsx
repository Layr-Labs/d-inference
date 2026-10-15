import { machineStatus } from '../../presentation/status';
import { useState } from 'react';
import { ChevronRight, Play, Search } from 'lucide-react';
import type { Machine } from '../../../shared/contracts';
import { money, plural } from '../../format';
import { Button, Empty, Status } from '../../components/UI';
import { MachineIcon } from '../machines/MachineIcon';
import { isOnline, memoryLabel } from '../machines/fleet';
import styles from './fleet.module.css';

export function FleetMacs({
  machines,
  localID,
  onOpen,
  onStart,
  startDisabled = false,
  recent = false,
}: {
  machines: Machine[];
  localID: string;
  onOpen: (id: string) => void;
  /** Home's start action, offered on This Mac's card while it is stopped. */
  onStart?: () => void;
  startDisabled?: boolean;
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
        <span>{plural(machines.length, 'Mac')}</span>
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
          <span className={styles.earned}>Usage earnings · {recent ? 'Recent' : '7d'}</span>
          <span />
        </div>
        {visible.map((machine) => {
          const local = machine.id === localID;
          // Only This Mac can be started from here; other Macs are view only.
          const startable = local && machine.status === 'stopped' && !!onStart;
          return (
            <div key={machine.id} className={styles.row}>
              <button
                className={styles.tableRow}
                aria-label={`Open ${machine.name}`}
                onClick={() => onOpen(machine.id)}
              >
                <span className={styles.machineName}>
                  <MachineIcon name={machine.name} size={22} />
                  <span>
                    <strong>{machine.name}</strong>
                    <small>{local ? 'This Mac' : 'View only'}</small>
                    <small>
                      {machine.chip} · {memoryLabel(machine)}
                    </small>
                  </span>
                </span>
                <Status state={isOnline(machine.status) ? 'online' : 'offline'}>
                  {machineStatus(machine.status)}
                </Status>
                <span>{machine.models.length}</span>
                <strong className={styles.earned}>{money(machine.earnings_micro_usd)}</strong>
                <ChevronRight size={16} className={styles.open} aria-hidden data-open-affordance />
              </button>
              {startable && (
                <div className={styles.rowAction}>
                  <p>This Mac isn't serving requests. Choose models to start earning.</p>
                  <Button variant="primary" disabled={startDisabled} onClick={onStart}>
                    <Play size={14} /> Start serving
                  </Button>
                </div>
              )}
            </div>
          );
        })}
      </div>
      {!visible.length && <Empty title="No matching Macs" />}
    </section>
  );
}
