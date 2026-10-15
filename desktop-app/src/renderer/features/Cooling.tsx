import type { BackendState } from '../useBackend';
import { Empty, Header, Notice, Status } from '../components/UI';
import { coolingStale, coolingStatus } from './cooling/status';
import { CoolingControls } from './cooling/CoolingControls';
import { FanCards } from './cooling/FanCards';
import styles from './cooling/cooling.module.css';

export function Cooling({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const cooling = backend.cooling;
  // A stale reading is not shown as the current temperature or fan speed.
  const stale = coolingStale(cooling);
  const fans = cooling?.supported && !stale ? cooling.fans : [];
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Cooling"
        description="Keep sustained workloads comfortable."
        action={<Status state={cooling?.enabled ? 'online' : ''}>{coolingStatus(cooling)}</Status>}
      />
      {cooling?.error && <Notice>{cooling.error}</Notice>}
      <div className={styles.hero}>
        <div className={styles.temperature}>
          <span>GPU temperature</span>
          <strong>
            {cooling?.temperature == null || stale ? '—' : `${Math.round(cooling.temperature)}°`}
          </strong>
          <p>Cooling returns to macOS control when serving stops.</p>
        </div>
        {fans.length > 0 && <FanCards fans={fans} />}
      </div>
      {cooling?.supported && cooling.control_available !== false ? (
        <CoolingControls backend={backend} />
      ) : (
        <Empty title="Automatic cooling">
          This Mac does not report supported fan controls. macOS manages cooling automatically.
        </Empty>
      )}
    </>
  );
}
