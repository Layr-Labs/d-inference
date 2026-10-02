import { useState } from 'react';
import { Fan } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { compact } from '../format';
import { Button, Empty, Header, Notice, Status } from '../components/UI';

export function Cooling({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const cooling = backend.cooling;
  const [speed, setSpeed] = useState(70);
  const [temperature, setTemperature] = useState(50);
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Cooling"
        description="Keep sustained workloads comfortable."
        action={
          <Status state={cooling?.mode === 'manual' ? 'online' : ''}>
            {cooling?.mode || 'Checking'}
          </Status>
        }
      />
      {cooling?.error && <Notice>{cooling.error}</Notice>}
      <div className="cooling-hero">
        <Fan size={86} strokeWidth={0.8} />
        <div>
          <span className="muted">GPU temperature</span>
          <strong>
            {cooling?.temperature == null ? '—' : `${Math.round(cooling.temperature)}°`}
          </strong>
          <p>Cooling returns to macOS control when the provider stops.</p>
        </div>
      </div>
      {!cooling?.supported ? (
        <Empty title="Automatic cooling">
          This Mac does not report supported fan controls. macOS manages cooling automatically.
        </Empty>
      ) : (
        <>
          <div className="fan-grid">
            {cooling.fans.map((fan, i) => (
              <div key={i}>
                <span>{fan.name}</span>
                <strong>
                  {compact(fan.rpm)} <small>RPM</small>
                </strong>
                <div className="memory-track">
                  <span style={{ width: `${Math.min(100, (fan.rpm / fan.max_rpm) * 100)}%` }} />
                </div>
              </div>
            ))}
          </div>
          <section className="settings-section">
            <h2>Provider cooling</h2>
            <label className="setting-row">
              <span>
                <strong>Fan speed</strong>
                <small>Percentage of the supported maximum.</small>
              </span>
              <div className="range-field">
                <input
                  aria-label="Fan speed"
                  type="range"
                  min={30}
                  max={100}
                  value={speed}
                  onChange={(e) => setSpeed(Number(e.target.value))}
                />
                <span>{speed}%</span>
              </div>
            </label>
            <label className="setting-row">
              <span>
                <strong>Engage above</strong>
                <small>Only while the provider is active.</small>
              </span>
              <select value={temperature} onChange={(e) => setTemperature(Number(e.target.value))}>
                {[40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90].map((t) => (
                  <option value={t} key={t}>
                    {t}°C
                  </option>
                ))}
              </select>
            </label>
            <div className="action-row">
              <Button
                variant="primary"
                disabled={backend.busy}
                onClick={() =>
                  void backend.act({ action: 'cooling', enabled: true, speed, temperature })
                }
              >
                Enable provider cooling
              </Button>
              <Button
                disabled={backend.busy}
                onClick={() => void backend.act({ action: 'cooling', enabled: false })}
              >
                Use macOS defaults
              </Button>
            </div>
            <p className="muted">macOS will request administrator authorization.</p>
          </section>
        </>
      )}
    </>
  );
}
