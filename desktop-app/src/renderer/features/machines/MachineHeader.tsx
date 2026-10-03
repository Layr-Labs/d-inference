import { Play, RotateCw, Square } from 'lucide-react';
import type { Machine, Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { MachineIcon } from './MachineIcon';
import styles from './machines.module.css';

export function MachineHeader({
  machine,
  local,
  backend,
  navigate,
}: {
  machine: Machine;
  local: boolean;
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  return (
    <header className={styles.machineHeader}>
      <div className={styles.machineTitle}>
        <div className={styles.deviceIcon}>
          <MachineIcon name={machine.name} size={30} strokeWidth={1.4} />
        </div>
        <div>
          <h1>
            {machine.name} <small>{local ? 'This Mac' : 'View only'}</small>
          </h1>
          <p>
            {machine.chip} ·{' '}
            {machine.memory_gb ? `${machine.memory_gb} GB unified memory` : 'Memory unknown'}
          </p>
        </div>
      </div>
      {local && (
        <div className={styles.actions}>
          <Button
            disabled={backend.busy || state.state === 'draining'}
            onClick={() =>
              state.state === 'running' ? void backend.act({ action: 'stop' }) : navigate('models')
            }
          >
            {state.state === 'running' ? <Square size={12} /> : <Play size={13} />}{' '}
            {state.state === 'running'
              ? 'Stop provider'
              : state.state === 'draining'
                ? 'Finishing requests'
                : 'Start provider'}
          </Button>
          <Button
            title="Restart provider"
            aria-label="Restart"
            disabled={backend.busy}
            onClick={() => void backend.act({ action: 'restart' })}
          >
            <RotateCw size={15} />
          </Button>
        </div>
      )}
    </header>
  );
}
