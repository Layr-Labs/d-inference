import { Eye } from 'lucide-react';
import type { Machine } from '../../../../shared/contracts';
import { age } from '../../../format';
import type { Presence } from './presence';
import styles from './remote.module.css';

const presenceText: Record<Presence, string> = {
  online: 'Online',
  stale: 'Not reporting',
  offline: 'Offline',
};

export function RemoteStatus({ machine, presence }: { machine: Machine; presence: Presence }) {
  return (
    <div className={styles.status}>
      <span role="status" className={styles.presence}>
        <i data-presence={presence} aria-hidden="true" />
        {presenceText[presence]}
        {presence === 'stale' && <small>last reported {machine.status}</small>}
      </span>
      <span className={styles.viewOnly}>
        <Eye size={12} aria-hidden="true" />
        View only. Controls for this Mac are in the Darkbloom app running on it.
      </span>
      <small>Last observed {age(machine.observed_at).toLowerCase()}</small>
    </div>
  );
}
