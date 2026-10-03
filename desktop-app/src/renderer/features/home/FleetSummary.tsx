import { useId } from 'react';
import type { BackendState } from '../../useBackend';
import { fleetMachines } from '../machines/fleet';
import { FleetEarnings } from './FleetEarnings';
import { FleetMacs } from './FleetMacs';
import styles from './fleet.module.css';

export function FleetSummary({
  backend,
  openMachine,
  onEarnings,
}: {
  backend: BackendState;
  openMachine: (id: string) => void;
  onEarnings: () => void;
}) {
  const state = backend.state!;
  const titleID = useId();
  return (
    <section className={styles.fleet} aria-labelledby={titleID}>
      <div className={styles.heading}>
        <h2 id={titleID}>Across your Macs</h2>
        <p>Earnings and status for every Mac on your account.</p>
      </div>
      <FleetEarnings backend={backend} onEarnings={onEarnings} />
      <FleetMacs
        machines={fleetMachines(state, backend.cloud)}
        localID={state.machine.id}
        onOpen={openMachine}
      />
      {!backend.cloud?.linked && (
        <p className={styles.caption}>
          Link each Mac to the same account to see its status and earnings here.
        </p>
      )}
    </section>
  );
}
