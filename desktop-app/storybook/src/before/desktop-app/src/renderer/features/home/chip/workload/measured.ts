import type { MemoryMap } from '../memoryMap';
import { clamp } from '../geometry';
import type { LiveReading } from './live';
import type { WorkloadFrame } from './types';

/** Live allocation and request counts. No sampled sequences, request phases or traffic. */
export function measuredFrame(
  reading: LiveReading,
  memory: MemoryMap,
  providerGb: number | null,
): WorkloadFrame {
  const weightsEnd = memory.segments.find((segment) => segment.kind === 'kv')?.from ?? 0;
  const kvEnd = memory.segments.find((segment) => segment.kind === 'kv')?.to ?? weightsEnd;
  const used = providerGb === null || memory.totalGb <= 0 ? null : providerGb / memory.totalGb;
  return {
    time: 0,
    mode: reading.inputs.mode,
    phase: reading.inputs.mode === 'stopped' ? 'stopped' : 'ready',
    power: 1,
    resident: memory.models.length ? 1 : 0,
    prefill: 0,
    decode: 0,
    decodeByModel: [],
    memoryRead: 0,
    kvFill:
      used === null || kvEnd <= weightsEnd ? 0 : clamp((used - weightsEnd) / (kvEnd - weightsEnd)),
    kvWrite: 0,
    cpu: 0,
    tokensPerSecond: reading.fresh ? reading.inputs.tokensPerSecond : 0,
    running: reading.fresh ? reading.inputs.running : 0,
    waiting: reading.fresh ? reading.inputs.waiting : 0,
    stepPhase: 0,
    steps: 0,
    sinceArrival: 0,
    sincePrefill: 0,
    sinceFlood: 0,
  };
}
