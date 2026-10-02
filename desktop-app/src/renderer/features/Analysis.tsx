import { ShieldCheck } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { compact, gb } from '../format';
import { Button, External, Header, Status } from '../components/UI';
import { ActivityChart } from './Home';

export function Analysis({ backend }: { backend: BackendState }) {
  const state = backend.state!;
  return (
    <>
      <Header
        title="Analysis"
        description="Operational activity reported by this Mac."
        action={
          <Button disabled={backend.busy} onClick={() => void backend.act({ action: 'diagnose' })}>
            <ShieldCheck size={16} /> Run diagnostics
          </Button>
        }
      />
      <div className="metric-row">
        <div>
          <span>Requests served · this session</span>
          <strong>{compact(state.activity.requests)}</strong>
        </div>
        <div>
          <span>Tokens generated</span>
          <strong>{compact(state.activity.tokens)}</strong>
        </div>
        <div>
          <span>Active model memory</span>
          <strong>{gb(state.memory.active_gb)}</strong>
        </div>
      </div>
      <section className="section">
        <h2>Requests over time</h2>
        <ActivityChart backend={backend} />
        <p className="muted">Observed intervals only. Activity does not establish paid work.</p>
      </section>
      <section className="section">
        <h2>Readiness</h2>
        <div className="plain-row">
          <Status state={state.state === 'running' ? 'online' : 'offline'}>
            {state.readiness}
          </Status>
        </div>
        <div className="plain-row">
          <span>Runtime version</span>
          <code>{state.version}</code>
        </div>
        <div className="plain-row">
          <span>Local API</span>
          <span>{state.endpoint ? 'Available' : 'Not enabled'}</span>
        </div>
        <External target="docs">Troubleshooting guide</External>
      </section>
    </>
  );
}
