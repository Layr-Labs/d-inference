import { count } from '../../../format';
import type { HardwareReadout } from './hardware/readouts';
import { ChipStatus } from './ChipStatus';
import { HardwareReadouts } from './HardwareReadouts';
import type { WorkloadPhase } from './workload/types';
import styles from './chip.module.css';

export function ChipReadouts({
  mode,
  live,
  phase,
  tokensPerSecond,
  running,
  waiting,
  hardware,
  showMode = true,
}: {
  mode: string;
  showMode?: boolean;
  /** Fresh measurements drive the chip. */
  live: boolean;
  /** Measured figures, shown whenever this Mac reports its hardware. */
  hardware: HardwareReadout | null;
  phase: WorkloadPhase | null;
  tokensPerSecond: number | null;
  running: number | null;
  waiting: number | null;
}) {
  return (
    <div className={styles.readouts}>
      {showMode && <ChipStatus mode={mode} live={live} />}
      {tokensPerSecond !== null && (
        <div className={styles.rate}>
          <strong>{count(tokensPerSecond)}</strong>
          <span>tokens per second</span>
        </div>
      )}
      {(running !== null || waiting !== null) && (
        <dl className={styles.counts}>
          {running !== null && (
            <div>
              <dt>In progress</dt>
              <dd>{count(running)}</dd>
            </div>
          )}
          {waiting !== null && (
            <div>
              <dt>Waiting</dt>
              <dd>{count(waiting)}</dd>
            </div>
          )}
        </dl>
      )}
      {hardware && <HardwareReadouts readout={hardware} />}
      {phase && (
        <span className={styles.phase} data-phase={phase}>
          {phase[0].toUpperCase() + phase.slice(1)}
        </span>
      )}
    </div>
  );
}
