import { useEffect, useId, useState } from 'react';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import styles from './cooling.module.css';

const thresholds = [40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90];
const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));
// The CLI accepts any threshold, so a configured value between the presets is offered as itself;
// the select then shows exactly what Enable submits.
const thresholdOptions = (current: number) =>
  thresholds.includes(current) ? thresholds : [...thresholds, current].sort((a, b) => a - b);

export function CoolingControls({ backend }: { backend: BackendState }) {
  const [speed, setSpeed] = useState(70);
  const [temperature, setTemperature] = useState(50);
  const titleID = useId();
  useEffect(() => {
    // Native cooling accepts whole numbers: 60–90 % speed and a 40–90 °C threshold.
    if (backend.cooling?.speed != null) setSpeed(Math.round(clamp(backend.cooling.speed, 60, 90)));
    if (backend.cooling?.threshold != null)
      setTemperature(Math.round(clamp(backend.cooling.threshold, 40, 90)));
  }, [backend.cooling?.speed, backend.cooling?.threshold]);
  return (
    <section className={styles.controls} aria-labelledby={titleID}>
      <h2 id={titleID}>Cooling while serving</h2>
      <div className={styles.fields}>
        <label className={styles.field}>
          <span>
            Fan speed <b>{speed}%</b>
          </span>
          <input
            aria-label="Fan speed"
            type="range"
            min={60}
            max={90}
            value={speed}
            onChange={(e) => setSpeed(Number(e.target.value))}
          />
          <small>Percentage of the supported maximum.</small>
        </label>
        <label className={styles.field}>
          <span>Engage above</span>
          <select
            aria-label="Engage above"
            value={temperature}
            onChange={(e) => setTemperature(Number(e.target.value))}
          >
            {thresholdOptions(temperature).map((t) => (
              <option value={t} key={t}>
                {t}°C
              </option>
            ))}
          </select>
          <small>Only while this Mac is serving.</small>
        </label>
      </div>
      <div className={styles.actions}>
        <Button
          variant="primary"
          disabled={backend.busy}
          onClick={() => void backend.act({ action: 'cooling', enabled: true, speed, temperature })}
        >
          Enable provider cooling
        </Button>
        <Button
          disabled={backend.busy}
          onClick={() => void backend.act({ action: 'cooling', enabled: false })}
        >
          Use macOS defaults
        </Button>
        <small>macOS will request administrator authorization.</small>
      </div>
    </section>
  );
}
