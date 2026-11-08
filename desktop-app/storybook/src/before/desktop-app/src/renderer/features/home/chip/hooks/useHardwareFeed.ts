import { useEffect, useMemo, useRef } from 'react';
import type { HardwareLoadState } from '../../../../hardware/useHardwareLoad';
import type { ChipAnatomy } from '../anatomy';
import { createHardwareDrive, type HardwareDrive } from '../hardware/drive';
import { hardwareTargets, sessionPeakPower, type HardwareTargets } from '../hardware/targets';

/** Read by the frame loop: the latest measured targets, and the drive that eases them. */
export interface HardwareFeed {
  current(): HardwareTargets | null;
  drive: HardwareDrive;
}

/**
 * Turns each 1 Hz sample into light targets held in a ref, so samples reach the frame loop
 * without re-rendering per frame. Measurements drive the chip only while they are fresh and
 * the drawing is this Mac's reported topology.
 */
export function useHardwareFeed(
  load: HardwareLoadState,
  anatomy: ChipAnatomy,
  providerGb: number | null = null,
) {
  const live = anatomy.source === 'topology' && load.fresh && load.sample !== null;
  const targets = useRef<HardwareTargets | null>(null),
    peak = useRef(0);
  useEffect(() => {
    if (!live || !load.sample) {
      targets.current = null;
      return;
    }
    peak.current = sessionPeakPower(peak.current, load.sample, anatomy);
    targets.current = hardwareTargets(load.sample, anatomy, peak.current, providerGb);
  }, [live, load.sample, anatomy, providerGb]);
  const feed = useMemo<HardwareFeed>(
    () => ({ current: () => targets.current, drive: createHardwareDrive() }),
    [],
  );
  return { feed, live };
}
