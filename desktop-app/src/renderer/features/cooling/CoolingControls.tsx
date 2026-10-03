import { useId, useState } from 'react';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import styles from './cooling.module.css';

const thresholds = [40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90];

export function CoolingControls({ backend }: { backend: BackendState }) {
  const [speed, setSpeed] = useState(70);
  const [temperature, setTemperature] = useState(50);
  const titleID = useId();
  return (
    <section className={styles.controls} aria-labelledby={titleID}>
      <h2 id={titleID}>Provider cooling</h2>
      <div className={styles.fields}>
        <label className={styles.field}>
          <span>
            Fan speed <b>{speed}%</b>
          </span>
          <input
            aria-label="Fan speed"
            type="range"
            min={30}
            max={100}
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
            {thresholds.map((t) => (
              <option value={t} key={t}>
                {t}°C
              </option>
            ))}
          </select>
          <small>Only while the provider is active.</small>
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
