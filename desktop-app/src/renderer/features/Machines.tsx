import { useState } from 'react';
import { ArrowUpRight, Laptop, Monitor, Play, RotateCw, Square } from 'lucide-react';
import type { BackendState } from '../useBackend';
import type { Route } from '../../shared/contracts';
import { Button, Notice, OperationFeed } from '../components/UI';
import { Models } from './Models';
import { Cooling } from './Cooling';
import { Analysis } from './Analysis';
import { Settings } from './Settings';
import { Studio } from './Studio';
import { MachineRail } from './machines/MachineRail';
import { FleetOverview } from './machines/FleetOverview';
import { MachineOverview } from './machines/MachineOverview';
import { machineTabs } from './machines/navigation';
import styles from './machines/machines.module.css';

export function Machines({
  backend,
  navigate,
  route = 'machines',
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
  route?: Route;
}) {
  const state = backend.state!;
  const [selectedID, setSelectedID] = useState<string | null>(
    route === 'machines' ? null : state.machine.id,
  );
  const machines = [
    {
      ...state.machine,
      status: state.state,
      earnings_micro_usd: backend.cloud?.local_earnings_micro_usd,
    },
    ...(backend.cloud?.machines || []).filter((machine) => machine.id !== state.machine.id),
  ];
  const effectiveID = route === 'machines' ? selectedID : state.machine.id;
  const machine = machines.find((machine) => machine.id === effectiveID);
  const local = machine?.id === state.machine.id;
  const select = (id: string | null) => {
    setSelectedID(id);
    navigate('machines');
  };
  const Icon = machine?.name.includes('Book') ? Laptop : Monitor;
  return (
    <div className={styles.workspace}>
      <MachineRail
        machines={machines}
        selected={machine?.id || null}
        localID={state.machine.id}
        onSelect={select}
      />
      <div className={styles.content}>
        {(!machine || local) && <OperationFeed backend={backend} inline />}
        {backend.cloud?.error && <Notice>{backend.cloud.error}</Notice>}
        {!machine ? (
          <FleetOverview
            backend={backend}
            machines={machines}
            select={select}
            onEarnings={() => navigate('earnings')}
          />
        ) : (
          <>
            <div className={styles.breadcrumb}>
              <button onClick={() => select(null)}>Fleet overview</button>
              <span>/</span>
              <span>{machine.name}</span>
            </div>
            <header className={styles.machineHeader}>
              <div className={styles.machineTitle}>
                <div className={styles.deviceIcon}>
                  <Icon size={30} strokeWidth={1.4} />
                </div>
                <div>
                  <h1>
                    {machine.name} <small>{local ? 'This Mac' : 'View only'}</small>
                  </h1>
                  <p>
                    {machine.chip} ·{' '}
                    {machine.memory_gb
                      ? `${machine.memory_gb} GB unified memory`
                      : 'Memory unknown'}
                  </p>
                </div>
              </div>
              {local && (
                <div className={styles.actions}>
                  <Button
                    disabled={backend.busy || state.state === 'draining'}
                    onClick={() =>
                      state.state === 'running'
                        ? void backend.act({ action: 'stop' })
                        : navigate('models')
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
                      onClick={() => {
                        setSelectedID(state.machine.id);
                        navigate(tab.route);
                      }}
                    >
                      {tab.label}
                    </button>
                  ))}
                </nav>
              </>
            )}
            <div className={styles.panel} key={`${machine.id}:${route}`}>
              {(!local || route === 'machines') && (
                <MachineOverview
                  machine={machine}
                  local={local}
                  backend={backend}
                  navigate={navigate}
                />
              )}
              {local && route === 'models' && <Models backend={backend} embedded />}
              {local && route === 'cooling' && <Cooling backend={backend} embedded />}
              {local && route === 'analysis' && <Analysis backend={backend} embedded />}
              {local && route === 'settings' && <Settings backend={backend} embedded />}
              {local && route === 'studio' && <Studio backend={backend} embedded />}
            </div>
          </>
        )}
      </div>
    </div>
  );
}
