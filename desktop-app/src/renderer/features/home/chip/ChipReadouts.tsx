import { count } from '../../../format';
import type { HardwareReadout } from './hardware/readouts';
import { HardwareReadouts } from './HardwareReadouts';
import { PHASE_TEXT } from './phaseText';
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
}: {
  mode: string;
  /** Fresh measurements drive the chip. */
  live: boolean;
  /** Measured figures, shown whenever this Mac reports its hardware. */
  hardware: HardwareReadout | null;
  phase: WorkloadPhase;
  tokensPerSecond: number | null;
  running: number | null;
  waiting: number | null;
}) {
  return (
    <div className={styles.readouts}>
      <span className={styles.mode} data-live={live}>
        {mode}
      </span>
      <div className={styles.rate}>
        <strong>{count(tokensPerSecond)}</strong>
        <span>tokens per second</span>
      </div>
      <dl className={styles.counts}>
        <div>
          <dt>In progress</dt>
          <dd>{count(running)}</dd>
        </div>
        <div>
          <dt>Waiting</dt>
          <dd>{count(waiting)}</dd>
        </div>
      </dl>
      {hardware && <HardwareReadouts readout={hardware} />}
      <span className={styles.phase} data-phase={phase}>
        {PHASE_TEXT[phase]}
      </span>
    </div>
  );
}
