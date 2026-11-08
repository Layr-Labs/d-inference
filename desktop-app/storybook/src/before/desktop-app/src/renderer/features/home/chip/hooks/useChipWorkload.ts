import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { Snapshot } from '../../../../../shared/contracts';
import type { ChipAnatomy } from '../anatomy';
import type { LitFrame } from '../hardware/drive';
import type { MemoryMap } from '../memoryMap';
import { hashString } from '../random';
import { createWorkloadEngine } from '../workload/engine';
import { measuredFrame } from '../workload/measured';
import { providerUp, readLive, type LiveReading, type LiveSample } from '../workload/live';
import { IDLE_INPUTS, type WorkloadInputs, type WorkloadPhase } from '../workload/types';
import type { HardwareFeed } from './useHardwareFeed';

export interface ChipStats {
  phase: WorkloadPhase;
  tokensPerSecond: number;
  running: number;
  waiting: number;
  prefill: number;
  decode: number;
  kv: number;
  traffic: number;
  neural: number;
}
const PREVIEW_IDLE: WorkloadInputs = { ...IDLE_INPUTS, mode: 'idle' };
const STATS_INTERVAL = 0.4,
  PREVIEW_WARMUP = 18,
  STALENESS_CHECK_MS = 2000;
const quantize = (value: number) => Math.round(value * 20) / 20;
const summarize = ({ workload: frame, hardware }: LitFrame): ChipStats => ({
  phase: frame.phase,
  tokensPerSecond: Math.round(frame.tokensPerSecond),
  running: frame.running,
  waiting: frame.waiting,
  prefill: quantize(frame.prefill),
  decode: quantize(frame.decode),
  kv: quantize(frame.kvFill),
  traffic: quantize(frame.memoryRead),
  neural: hardware ? quantize(hardware.weight * hardware.ane.known * hardware.ane.value) : 0,
});
const sameStats = (a: ChipStats, b: ChipStats) =>
  (Object.keys(a) as (keyof ChipStats)[]).every((key) => a[key] === b[key]);

/** Drives live allocation/count frames and hardware measurements; simulations exist only in preview. */
export function useChipWorkload({
  state,
  preview,
  anatomy,
  memory,
  hardware,
  providerGb,
}: {
  state: Snapshot;
  preview: boolean;
  anatomy: ChipAnatomy;
  memory: MemoryMap;
  hardware: HardwareFeed;
  providerGb: number | null;
}) {
  const modelIds = useMemo(() => memory.models.map((model) => model.id), [memory]);
  const engine = useMemo(
    () =>
      preview
        ? createWorkloadEngine({
            seed: hashString(`${anatomy.name}:preview`),
            anatomy,
            models: modelIds.length,
            warmup: PREVIEW_WARMUP,
          })
        : null,
    [anatomy, modelIds.length, preview],
  );
  const sample = useRef<LiveSample | null>(null);
  const liveReading = useRef<LiveReading>({ inputs: IDLE_INPUTS, sample: null, fresh: false });
  const [reading, setReading] = useState<LiveReading>({
    inputs: IDLE_INPUTS,
    sample: null,
    fresh: false,
  });
  const [clock, setClock] = useState(0);
  useEffect(() => {
    const timer = setInterval(() => setClock((value) => value + 1), STALENESS_CHECK_MS);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    const next = readLive(state, modelIds, sample.current, Date.now() / 1000);
    sample.current = next.sample;
    liveReading.current = next;
    setReading(next);
  }, [state, modelIds, clock]);

  const powered = providerUp(state.state);
  const inputs = useRef<WorkloadInputs>(IDLE_INPUTS);
  useEffect(() => {
    inputs.current = preview
      ? { ...IDLE_INPUTS, mode: powered ? 'synthetic' : 'stopped' }
      : reading.inputs;
  }, [preview, powered, reading]);

  const [stats, setStats] = useState(() =>
    summarize({
      workload: engine?.frame ?? measuredFrame(reading, memory, providerGb),
      hardware: null,
    }),
  );
  const sinceStats = useRef(0);
  const advance = useCallback(
    (elapsed: number) => {
      const measured = hardware.current();
      // Preview arrivals are invented, so they pause while the measured GPU is not serving.
      const idle = preview && measured && !measured.serving && inputs.current.mode === 'synthetic';
      const lit = hardware.drive.step(
        elapsed,
        preview
          ? engine!.step(elapsed, idle ? PREVIEW_IDLE : inputs.current)
          : measuredFrame(liveReading.current, memory, providerGb),
        measured,
      );
      sinceStats.current += elapsed;
      if (sinceStats.current >= STATS_INTERVAL) {
        sinceStats.current = 0;
        const next = summarize(lit);
        setStats((previous) => (sameStats(previous, next) ? previous : next));
      }
      return lit;
    },
    [engine, hardware, preview, memory, providerGb],
  );
  return { advance, stats, reading, powered };
}
