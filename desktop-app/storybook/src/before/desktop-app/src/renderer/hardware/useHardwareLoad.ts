import { useEffect, useState } from 'react';
import type { DesktopAPI } from '../../shared/contracts';
import {
  hardwareProtocolVersion,
  type HardwareLoad,
  type HardwareSample,
  type HardwareTopology,
} from '../../shared/hardware';
import { api } from '../useBackend';
import { isFresh, msUntilStale, newerSample } from './freshness';

export interface HardwareLoadState {
  topology: HardwareTopology | null;
  // Whole-machine load, also while the provider is stopped. Darkbloom's part is
  // sample.gpu.provider_share; sample.provider.running says whether it serves.
  sample: HardwareSample | null;
  // sampled_at is less than three seconds old.
  fresh: boolean;
  capabilities: HardwareSample['capabilities'];
}

const visible = () => document.visibilityState === 'visible';
const noCapabilities: HardwareSample['capabilities'] = Object.freeze({});

// Live machine load. Subscribes only while mounted and the window is visible,
// so the runtime stops sampling when nobody is looking.
export function useHardwareLoad(source: DesktopAPI | undefined = api): HardwareLoadState {
  const [topology, setTopology] = useState<HardwareTopology | null>(null);
  const [sample, setSample] = useState<HardwareSample | null>(null);
  const [shown, setShown] = useState(visible);
  const [, setClock] = useState(0);

  useEffect(() => {
    const update = () => setShown(visible());
    document.addEventListener('visibilitychange', update);
    return () => document.removeEventListener('visibilitychange', update);
  }, []);

  useEffect(() => {
    if (!source || !shown) return;
    let active = true;
    const accept = (next: HardwareSample) => {
      if (active) setSample((current) => newerSample(current, next));
    };
    source
      .read<HardwareLoad>('hardware')
      .then((load) => {
        if (!active || load.protocol !== hardwareProtocolVersion) return;
        setTopology(load.topology);
        if (load.sample) accept(load.sample);
      })
      .catch(() => {});
    const unsubscribe = source.onHardware(accept);
    return () => {
      active = false;
      unsubscribe();
    };
  }, [source, shown]);

  // Re-render when the current sample ages out so `fresh` drops without a new frame.
  useEffect(() => {
    const remaining = msUntilStale(sample);
    if (remaining <= 0) return;
    const timer = setTimeout(() => setClock((tick) => tick + 1), remaining + 1);
    return () => clearTimeout(timer);
  }, [sample]);

  return {
    topology,
    sample,
    fresh: isFresh(sample),
    capabilities: sample?.capabilities ?? noCapabilities,
  };
}
