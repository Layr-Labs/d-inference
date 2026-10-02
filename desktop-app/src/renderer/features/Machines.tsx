import { useState } from 'react';
import { ArrowLeft, ArrowUpRight, Monitor, MoreHorizontal, RotateCw } from 'lucide-react';
import type { BackendState } from '../useBackend';
import type { Machine, Route } from '../../shared/contracts';
import { age, gb, money } from '../format';
import { Button, Empty, Header, Notice, Status } from '../components/UI';
import { ActivityChart } from './Home';

export function Machines({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const [selected, setSelected] = useState<Machine>();
  const state = backend.state!;
  const machines = [
    { ...state.machine, earnings_micro_usd: backend.cloud?.local_earnings_micro_usd },
    ...(backend.cloud?.machines || []).filter((machine) => machine.id !== state.machine.id),
  ];
  if (selected) {
    const isLocal = selected.id === state.machine.id;
    const machine = isLocal
      ? { ...state.machine, earnings_micro_usd: backend.cloud?.local_earnings_micro_usd }
      : selected;
    return (
      <>
        <button className="text-link back" onClick={() => setSelected(undefined)}>
          <ArrowLeft size={15} /> My Macs
        </button>
        <Header
          title={machine.name}
          description={`${machine.chip} · ${machine.memory_gb} GB unified memory`}
          action={
            <Status
              state={
                machine.status === 'running' ||
                machine.status === 'online' ||
                machine.status === 'serving'
                  ? 'online'
                  : 'offline'
              }
            >
              {machine.status}
            </Status>
          }
        />
        {!isLocal && (
          <Notice>
            Remote Mac · Status and earnings only. Last observed{' '}
            {age(machine.observed_at).toLowerCase()}.
          </Notice>
        )}
        <div className="metric-row">
          <div>
            <span>Usage earnings · 7 days</span>
            <strong>{money(machine.earnings_micro_usd)}</strong>
          </div>
          <div>
            <span>Serving models</span>
            <strong>{machine.models.length}</strong>
          </div>
          <div>
            <span>Provider version</span>
            <strong>{machine.version || '—'}</strong>
          </div>
        </div>
        {isLocal && (
          <>
            <div className="action-row">
              <Button onClick={() => navigate('models')}>Manage models</Button>
              <Button
                disabled={backend.busy}
                onClick={() => void backend.act({ action: 'restart' })}
              >
                <RotateCw size={15} /> Restart
              </Button>
              <Button
                disabled={backend.busy || state.state === 'stopped'}
                onClick={() => void backend.act({ action: 'stop' })}
              >
                Stop provider
              </Button>
            </div>
            <section className="section">
              <div className="section-title">
                <h2>Request activity</h2>
              </div>
              <ActivityChart backend={backend} />
            </section>
            <div className="setting-links">
              {(['cooling', 'analysis', 'settings'] as Route[]).map((route) => (
                <button key={route} onClick={() => navigate(route)}>
                  <span>{route[0].toUpperCase() + route.slice(1)}</span>
                  <ArrowUpRight size={18} />
                </button>
              ))}
            </div>
          </>
        )}
        <section className="section">
          <h2>Serving models</h2>
          {machine.models.length ? (
            machine.models.map((model) => (
              <div className="plain-row" key={model}>
                {model}
              </div>
            ))
          ) : (
            <p className="muted">No serving models reported.</p>
          )}
        </section>
      </>
    );
  }
  return (
    <>
      <Header
        title="My Macs"
        description="Every Mac you contribute. One place to see the difference."
        action={
          <Button onClick={() => void backend.refresh()}>
            <RotateCw size={15} /> Refresh
          </Button>
        }
      />
      <div className="metric-row">
        <div>
          <span>Earned all time</span>
          <strong>{money(backend.cloud?.lifetime_micro_usd)}</strong>
        </div>
        <div>
          <span>Past 7 days</span>
          <strong>{money(backend.cloud?.week_micro_usd)}</strong>
        </div>
        <div>
          <span>Your Macs</span>
          <strong>{machines.length}</strong>
        </div>
      </div>
      {backend.cloud?.error && <Notice>{backend.cloud.error}</Notice>}
      <div className="section-title">
        <h2>Your machines</h2>
        <span className="muted">{machines.length} connected to this view</span>
      </div>
      <div className="machine-table">
        <div className="table-head">
          <span>Mac</span>
          <span>Status</span>
          <span>Models</span>
          <span>Usage earnings · 7d</span>
          <span />
        </div>
        {machines.map((machine) => (
          <button
            className="machine-table-row"
            onClick={() => setSelected(machine)}
            key={machine.id}
          >
            <div className="machine-name">
              <Monitor size={23} strokeWidth={1.3} />
              <div>
                <strong>{machine.name}</strong>
                <small>
                  {machine.id === state.machine.id ? 'This Mac' : 'Remote'} · {machine.chip} ·{' '}
                  {gb(machine.memory_gb)}
                </small>
              </div>
            </div>
            <Status
              state={
                ['running', 'online', 'serving'].includes(machine.status) ? 'online' : 'offline'
              }
            >
              {machine.status}
            </Status>
            <span>{machine.models.length || '—'}</span>
            <strong>{money(machine.earnings_micro_usd)}</strong>
            <MoreHorizontal size={17} />
          </button>
        ))}
      </div>
      {!backend.cloud?.linked && (
        <Empty title="Connect your other Macs">
          Link each Mac to the same account to see its status and earnings here.
        </Empty>
      )}
    </>
  );
}
