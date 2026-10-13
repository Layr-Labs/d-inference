import { machineStatus } from '../../../presentation/status';
import { Eye } from 'lucide-react';
import type { Machine } from '../../../../shared/contracts';
import { age } from '../../../format';
import type { Presence } from './presence';
import styles from './remote.module.css';

// A Mac that is not online shows its reported status: starting, finishing requests or needing
// verification is not the same as offline.
const presenceText = (machine: Machine, presence: Presence) =>
  presence === 'online'
    ? 'Online'
    : presence === 'stale'
      ? 'Not reporting'
      : machineStatus(machine.status);

export function RemoteStatus({ machine, presence }: { machine: Machine; presence: Presence }) {
  return (
    <div className={styles.status}>
      <span role="status" className={styles.presence}>
        <i data-presence={presence} aria-hidden="true" />
        {presenceText(machine, presence)}
        {presence === 'stale' && <small>last reported {machineStatus(machine.status)}</small>}
      </span>
      <span className={styles.viewOnly}>
        <Eye size={12} aria-hidden="true" />
        View only. Controls for this Mac are in the Darkbloom app running on it.
      </span>
      <small>
        {machine.observed_at
          ? `Last observed ${age(machine.observed_at).toLowerCase()}`
          : 'Not observed yet'}
      </small>
    </div>
  );
}
