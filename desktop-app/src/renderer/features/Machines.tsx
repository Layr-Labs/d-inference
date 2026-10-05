import { ArrowUpRight } from 'lucide-react';
import type { BackendState } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { Notice, OperationFeed } from '../components/UI';
import { Models } from './models/Models';
import { Cooling } from './Cooling';
import { Stats } from './Stats';
import { Settings } from './Settings';
import { Studio } from './Studio';
import { MachineRail } from './machines/MachineRail';
import { MachineHeader } from './machines/MachineHeader';
import { LocalOverview } from './machines/overview/LocalOverview';
import { RemoteOverview } from './machines/overview/RemoteOverview';
import { fleetMachines } from './machines/fleet';
import { machineTabs, type MachineSelection } from './machines/navigation';
import styles from './machines/machines.module.css';

export function Machines({
  backend,
  navigate,
  onSelect,
  route = 'machines',
  machine = null,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
  onSelect: (id: string) => void;
  route?: Route;
  machine?: MachineSelection;
}) {
  const state = backend.state!;
  const machines = fleetMachines(state, backend.cloud);
  const selected =
    (route === 'machines' && machines.find((item) => item.id === machine)) || machines[0];
  const local = selected.id === state.machine.id;
  return (
    <div className={styles.workspace}>
      <MachineRail
        machines={machines}
        selected={selected.id}
        localID={state.machine.id}
        onSelect={onSelect}
      />
      <div className={styles.content}>
        {local && <OperationFeed backend={backend} inline />}
        {backend.cloud?.error && route === 'machines' && <Notice>{backend.cloud.error}</Notice>}
        <div className={styles.breadcrumb}>
          <span>My Macs</span>
          <span>/</span>
          <span>{selected.name}</span>
        </div>
        <MachineHeader machine={selected} local={local} backend={backend} navigate={navigate} />
        {local && (
          <>
            <div className={styles.shortcuts}>
              <button className="text-link" onClick={() => navigate('earnings')}>
                View earnings <ArrowUpRight size={13} />
              </button>
              <button
                className="text-link"
                aria-current={route === 'studio' ? 'page' : undefined}
                onClick={() => navigate('studio')}
              >
                Studio <ArrowUpRight size={13} />
              </button>
            </div>
            <nav className={styles.tabs} aria-label="Machine sections">
              {machineTabs.map((tab) => (
                <button
                  key={tab.route}
                  aria-current={route === tab.route ? 'page' : undefined}
                  onClick={() => navigate(tab.route)}
                >
                  {tab.label}
                </button>
              ))}
            </nav>
          </>
        )}
        <div className={styles.panel} key={`${selected.id}:${route}`}>
          {route === 'machines' &&
            (local ? (
              <LocalOverview backend={backend} navigate={navigate} />
            ) : (
              <RemoteOverview machine={selected} backend={backend} />
            ))}
          {local && route === 'models' && <Models backend={backend} embedded />}
          {local && route === 'cooling' && <Cooling backend={backend} embedded />}
          {local && route === 'analysis' && <Stats backend={backend} embedded />}
          {local && route === 'settings' && <Settings backend={backend} embedded />}
          {local && route === 'studio' && <Studio backend={backend} embedded />}
        </div>
      </div>
    </div>
  );
}
