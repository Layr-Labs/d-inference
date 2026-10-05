import { clamp, lerp } from '../geometry';
import type { WorkloadFrame } from '../workload/types';
import { resolvePhase } from './phase';
import type { HardwareTargets } from './targets';

/** A measured level eased toward each 1 Hz sample; `known` fades out while it is unknown. */
export interface Eased {
  value: number;
  known: number;
}
/** Measured load eased for drawing, with `weight` easing the initial connection. */
export interface HardwareLight {
  /** 0 without measurements, 1 while fresh measurements drive the chip. */
  weight: number;
  /** By logical CPU id. */
  cpu: Eased[];
  /** By anatomy cluster. */
  clusters: Eased[];
  cpuBusy: Eased;
  gpu: Eased;
  share: Eased;
  glow: Eased;
  clock: Eased;
  traffic: Eased;
  ane: Eased;
  other: Eased;
  /** 1 when Darkbloom's GPU time is prefill, 0 when decode. */
  prefillMix: number;
  /** GPU shimmer position in cycles; advances faster as the GPU clocks up. */
  wave: number;
}
export interface LitFrame {
  workload: WorkloadFrame;
  hardware: HardwareLight | null;
}

/** Samples land once a second; this time constant glides between them without lagging. */
const TAU = 0.35,
  ASLEEP = 0.001;
const channel = (): Eased => ({ value: 0, known: 0 });
const MIX: Partial<Record<WorkloadFrame['phase'], number>> = { prefill: 1, decode: 0, mixed: 0.5 };

function ease(target: Eased, next: number | null, k: number) {
  if (next === null) {
    target.known += (0 - target.known) * k;
    return;
  }
  target.value = target.known < 0.01 ? next : target.value + (next - target.value) * k;
  target.known += (1 - target.known) * k;
}
function easeAll(list: Eased[], next: (number | null)[], k: number) {
  while (list.length < next.length) list.push(channel());
  list.forEach((item, i) => ease(item, next[i] ?? null, k));
}

/** Decode steps per second: quicker with more tokens, compressed so it stays readable. */
const pulseRate = (tokensPerSecond: number, traffic: number) =>
  tokensPerSecond > 0.5
    ? clamp(0.6 + 0.9 * Math.log2(1 + tokensPerSecond / 25), 0.6, 4)
    : 0.6 + 1.2 * traffic;

/** Eases fresh measurements. Only explicit synthetic preview frames get illustrative motion. */
export function createHardwareDrive() {
  const light: HardwareLight = {
    weight: 0,
    cpu: [],
    clusters: [],
    cpuBusy: channel(),
    gpu: channel(),
    share: channel(),
    glow: channel(),
    clock: channel(),
    traffic: channel(),
    ane: channel(),
    other: channel(),
    prefillMix: 0,
    wave: 0,
  };
  let pulse = 0;

  return {
    step(elapsed: number, w: WorkloadFrame, targets: HardwareTargets | null): LitFrame {
      const liveOnly = w.mode !== 'synthetic';
      if (liveOnly && !targets) {
        light.weight = 0;
        return { workload: w, hardware: null };
      }
      const k = 1 - Math.exp(-Math.max(0, elapsed) / TAU),
        phase = targets ? resolvePhase(w.phase, w.mode, targets.phase, targets.serving) : w.phase;
      light.weight += ((targets ? 1 : 0) - light.weight) * k;
      if (targets) {
        easeAll(light.cpu, targets.cpu, k);
        easeAll(light.clusters, targets.clusters, k);
        ease(light.cpuBusy, targets.cpuBusy, k);
        ease(light.gpu, targets.gpu, k);
        ease(light.share, targets.share, k);
        ease(light.glow, targets.glow, k);
        ease(light.clock, targets.clock, k);
        ease(light.traffic, targets.traffic, k);
        ease(light.ane, targets.ane, k);
        ease(light.other, targets.other, k);
      }
      if (liveOnly) return { workload: w, hardware: light };
      const mix = MIX[phase];
      if (mix !== undefined) light.prefillMix += (mix - light.prefillMix) * k;
      light.wave += elapsed * (0.25 + 1.5 * light.clock.value);
      pulse = (pulse + elapsed * pulseRate(w.tokensPerSecond, light.traffic.value)) % 1;
      if (light.weight < ASLEEP) return { workload: w, hardware: null };

      const weight = light.weight,
        measured = (sim: number, level: Eased) => lerp(sim, level.value, weight * level.known),
        darkbloom = light.gpu.value * light.share.value,
        known = weight * light.gpu.known * light.share.known;
      return {
        workload: {
          ...w,
          phase,
          power: lerp(w.power, 1, weight),
          prefill: lerp(w.prefill, darkbloom * light.prefillMix, known),
          decode: lerp(w.decode, darkbloom * (1 - light.prefillMix), known),
          memoryRead:
            targets?.traffic === null
              ? lerp(w.memoryRead, 0, weight)
              : measured(w.memoryRead, light.traffic),
          kvWrite: targets?.traffic === null ? lerp(w.kvWrite, 0, weight) : w.kvWrite,
          cpu: measured(w.cpu, light.cpuBusy),
          stepPhase: weight >= 0.5 ? pulse : w.stepPhase,
        },
        hardware: light,
      };
    },
  };
}
export type HardwareDrive = ReturnType<typeof createHardwareDrive>;
