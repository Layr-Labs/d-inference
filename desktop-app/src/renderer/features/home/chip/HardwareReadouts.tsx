import type { HardwareReadout } from './hardware/readouts';
import styles from './chip.module.css';

export const WHOLE_GPU_NOTE = 'macOS reports GPU busy for the whole GPU, not per core.';

/** Measured load on this Mac, in real units. */
export function HardwareReadouts({ readout }: { readout: HardwareReadout }) {
  return (
    <div className={styles.hardware}>
      <dl aria-label="Measured on this Mac">
        <div title={WHOLE_GPU_NOTE}>
          <dt>GPU busy</dt>
          <dd>
            {readout.gpu}
            {readout.darkbloom !== null && (
              <small className={styles.share}>Darkbloom {readout.darkbloom}</small>
            )}
          </dd>
        </div>
        <div>
          <dt>GPU power</dt>
          <dd>{readout.power}</dd>
        </div>
        <div>
          <dt>GPU clock</dt>
          <dd>{readout.clock}</dd>
        </div>
        <div>
          <dt>Memory traffic</dt>
          <dd>
            {readout.memory}
            {readout.memoryEstimated && <small className={styles.badge}>Estimated</small>}
          </dd>
        </div>
        <div>
          <dt>CPU busy</dt>
          <dd>{readout.cpu}</dd>
        </div>
      </dl>
      <p className={styles.note}>{WHOLE_GPU_NOTE}</p>
    </div>
  );
}
