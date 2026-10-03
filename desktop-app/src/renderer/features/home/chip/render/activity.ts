import { clamp, lerp, smoothstep } from '../geometry';
import type { Eased } from '../hardware/drive';
import type { Tile, Trace } from '../layout';
import { segmentAt, type MemoryKind, type MemoryMap } from '../memoryMap';
import { noise } from '../random';
import type { WorkloadFrame } from '../workload/types';
import type { RenderFrame } from './types';

/*
 * Shared light semantics for every renderer, so both variants light the same parts for the
 * same reasons. Simulated: prefill floods the GPU from the dispatch point, decode rolls in from
 * the memory interfaces once per step while a sweep crosses the weights it streams, and the KV
 * cache fills and drains with context. Measured (crossfaded in by `hardware.weight`): every GPU
 * core shows the one whole-GPU busy figure macOS reports, CPU cores their own load, and the
 * memory interfaces, traces and system cache the DRAM traffic.
 */
const FLOOD_SPEED = 2.8,
  RIPPLE_SPEED = 2.2;
const fract = (value: number) => value - Math.floor(value);
const tileSeed = (tile: Tile) => noise(tile.index * 7.13 + tile.die * 31.7 + tile.x * 0.011);
/** Blends a simulated level toward a measured one by how live and how known it is. */
const measured = (f: RenderFrame, sim: number, level: Eased | undefined) =>
  f.hardware && level ? lerp(sim, level.value, f.hardware.weight * level.known) : sim;

/** Brightness of a decode step's leading edge; peaks just after each step begins. */
export const stepPulse = (w: WorkloadFrame, motion: boolean) =>
  motion ? Math.exp(-((w.stepPhase - 0.06) ** 2) / 0.008) * clamp(w.decode * 4) : 0.4 * w.decode;

function simulatedGpu(tile: Tile, w: WorkloadFrame, motion: boolean) {
  let prefill = 0;
  if (w.prefill > 0.002) {
    const reached = motion ? smoothstep(0, 0.2, w.sinceFlood * FLOOD_SPEED - tile.dispatch) : 1;
    const ripple =
      motion && w.sincePrefill < 1.5
        ? Math.exp(-((w.sincePrefill * RIPPLE_SPEED - tile.dispatch) ** 2) / 0.006) * 0.45
        : 0;
    const shimmer = motion ? 0.9 + 0.1 * Math.sin(w.time * 5.3 + tileSeed(tile) * 6.283) : 1;
    prefill = w.prefill * clamp(reached * shimmer + ripple * reached, 0, 1.2);
  }
  const front = w.stepPhase * 1.35 - 0.2,
    band = motion ? Math.exp(-((tile.memory - front) ** 2) / 0.03) : 0.5;
  return { prefill, decode: w.decode * (0.45 + 0.55 * band) };
}

/**
 * GPU core light split into its prefill and decode shares. Measured, all cores share one
 * intensity, with a shimmer outward from the dispatch point that quickens with the clock.
 */
export function gpuLevel(tile: Tile, f: RenderFrame) {
  const sim = simulatedGpu(tile, f.workload, f.motion),
    hw = f.hardware;
  if (!hw) return sim;
  const weight = hw.weight * hw.gpu.known,
    shimmer = f.motion
      ? 0.86 + 0.14 * Math.sin(6.283 * (hw.wave - tile.dispatch * 0.9) + tileSeed(tile))
      : 1,
    level = hw.gpu.value * shimmer;
  return {
    prefill: lerp(sim.prefill, level * hw.prefillMix, weight),
    decode: lerp(sim.decode, level * (1 - hw.prefillMix), weight),
  };
}

/** Darkbloom's share of the GPU light; the rest is drawn neutral. */
export const gpuShare = (f: RenderFrame) => measured(f, 1, f.hardware?.share);

/** Measured GPU busy time that belongs to other apps. */
export const foreignGpu = (f: RenderFrame) => {
  const hw = f.hardware;
  return hw ? hw.weight * hw.gpu.known * hw.gpu.value * (1 - gpuShare(f)) : 0;
};

/** Halo strength from GPU power against the session peak, 1 when unmeasured. */
export const gpuGlow = (f: RenderFrame) =>
  f.hardware ? lerp(1, 0.3 + f.hardware.glow.value, f.hardware.weight * f.hardware.glow.known) : 1;

/** Simulated: P-cores take each arrival, E-cores stay near idle. Measured: each core's load. */
export function cpuLevel(tile: Tile, f: RenderFrame) {
  const { workload: w, motion, hardware: hw } = f;
  let sim: number;
  if (tile.kind === 'efficiency') sim = w.cpu * 0.14;
  else if (tile.kind === 'l2') sim = w.cpu * 0.4;
  else {
    const arrival = Math.round((w.time - w.sinceArrival) * 60),
      chosen = noise(arrival * 0.731 + tile.index * 3.17 + tile.die * 11.3) > 0.68;
    const flicker = motion ? 0.85 + 0.15 * Math.sin(w.time * 9 + tile.index * 2.1) : 1;
    sim = w.cpu * (chosen ? 1 : 0.22) * flicker;
  }
  if (!hw) return sim;
  const level =
    tile.kind === 'l2'
      ? hw.clusters[tile.cluster ?? -1]
      : (tile.cpu ?? -1) >= 0
        ? hw.cpu[tile.cpu!]
        : hw.cpuBusy;
  return measured(f, sim, level);
}

/** System-level cache banks: the conduit memory traffic flows through, not cache hits. */
export const cacheLevel = ({ workload: w, motion }: RenderFrame) =>
  w.memoryRead * (0.42 + 0.3 * stepPulse(w, motion));

export const interfaceLevel = ({ workload: w, motion }: RenderFrame) =>
  clamp(w.memoryRead * (0.55 + 0.45 * stepPulse(w, motion)) + w.kvWrite * 0.3);

/** Dark unless something actually runs on the Neural Engine; Darkbloom never does. */
export const neuralLevel = ({ hardware: hw }: RenderFrame) =>
  hw ? hw.weight * hw.ane.known * hw.ane.value : 0;

export interface CellLight {
  kind: MemoryKind;
  /** Loaded-model index for weight cells; -1 otherwise. */
  model: number;
  /** Resident-weights glow. */
  weights: number;
  /** KV occupancy of the cell, partially lit at the fill frontier. */
  kv: number;
  /** Transient highlight: decode sweep over weights/KV, or the KV write frontier. */
  sweep: number;
  /** Measured memory in use by everything else, filled from the top of the address space. */
  other: number;
}

/** `position` is the cell's place in the interleaved space; `span` is one cell's share. */
export function memoryCell(
  position: number,
  span: number,
  map: MemoryMap,
  f: RenderFrame,
): CellLight {
  const { workload: w, motion, hardware: hw } = f,
    segment = segmentAt(map, position + span / 2),
    size = Math.max(1e-6, segment.to - segment.from),
    local = (position - segment.from) / size,
    localSpan = span / size;
  const other = hw
    ? clamp((position + span - (1 - hw.other.value)) / span) * hw.weight * hw.other.known
    : 0;
  const sweepAt = w.stepPhase * 1.25 - 0.12;
  if (segment.kind === 'weights') {
    const breathe = motion ? 0.5 + 0.5 * Math.sin(w.time * 1.4) : 0.5;
    const sweep = motion
      ? (w.decodeByModel[segment.model] ?? w.decode) *
        Math.exp(-((local + localSpan / 2 - sweepAt) ** 2) / 0.006)
      : 0;
    return {
      kind: 'weights',
      model: segment.model,
      weights: w.resident * (0.55 + 0.25 * breathe),
      kv: 0,
      sweep,
      other: 0,
    };
  }
  if (segment.kind === 'kv') {
    const kv = clamp((w.kvFill - local) / localSpan),
      frontier = Math.exp(-((local - w.kvFill) ** 2) / 0.003) * clamp(w.kvWrite * 1.4);
    const read =
      motion && kv > 0 && w.kvFill > 0
        ? w.decode * 0.6 * Math.exp(-((local / w.kvFill - sweepAt) ** 2) / 0.01)
        : 0;
    return { kind: 'kv', model: -1, weights: 0, kv, sweep: Math.max(frontier, read), other };
  }
  return { kind: 'reserved', model: -1, weights: 0, kv: 0, sweep: 0, other };
}

export interface Pulse {
  /** 0 at the memory package end of the trace, 1 at the die end. */
  at: number;
  strength: number;
  write: boolean;
}
/** Reads stream from memory toward the die in step with decode; KV writes flow back. */
export function tracePulses(trace: Trace, { workload: w, motion }: RenderFrame): Pulse[] {
  if (!motion) return [];
  const seed = noise(trace.package * 17.3 + trace.lane * 3.1),
    pulses: Pulse[] = [];
  if (w.memoryRead > 0.04) {
    const clock = w.decode > 0.05 ? w.stepPhase : fract(w.time * 1.1);
    pulses.push({ at: fract(clock + seed * 0.3), strength: w.memoryRead, write: false });
    if (w.memoryRead > 0.6)
      pulses.push({
        at: fract(clock + seed * 0.3 + 0.5),
        strength: w.memoryRead * 0.6,
        write: false,
      });
  }
  if (w.kvWrite > 0.08)
    pulses.push({
      at: 1 - fract(w.time * 1.4 + seed * 1.7),
      strength: w.kvWrite * 0.85,
      write: true,
    });
  return pulses;
}

/** A request entering through the network/I/O block; null once it has arrived. */
export function ioPulse({ workload: w, motion }: RenderFrame) {
  const at = w.sinceArrival / 0.4;
  if (!motion || at < 0 || at > 1.3) return null;
  return { at: Math.min(1, at), strength: w.power * (1 - smoothstep(1, 1.3, at)) };
}
