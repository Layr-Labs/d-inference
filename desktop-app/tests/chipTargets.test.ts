import { describe, expect, it } from 'vitest';
import {
  createHardwareDrive,
  type LitFrame,
} from '../src/renderer/features/home/chip/hardware/drive';
import { hardwarePhase, resolvePhase } from '../src/renderer/features/home/chip/hardware/phase';
import { hardwareReadout } from '../src/renderer/features/home/chip/hardware/readouts';
import {
  hardwareTargets,
  sessionPeakPower,
} from '../src/renderer/features/home/chip/hardware/targets';
import { chipLayout } from '../src/renderer/features/home/chip/layout';
import { cpuLevel, gpuLevel, gpuShare } from '../src/renderer/features/home/chip/render/activity';
import type { RenderFrame } from '../src/renderer/features/home/chip/render/types';
import { anatomyFromTopology } from '../src/renderer/features/home/chip/topologyAnatomy';
import { createWorkloadEngine } from '../src/renderer/features/home/chip/workload/engine';
import { IDLE_INPUTS } from '../src/renderer/features/home/chip/workload/types';
import { previewHardwareSample, previewTopology } from '../src/renderer/previewHardware';
import type { HardwareSample } from '../src/shared/hardware';

const anatomy = anatomyFromTopology(previewTopology, '', 0);
/** Seconds into the preview cycle: idle 0–6, prefill 6–10, decode 10–24. */
const IDLE = 2,
  PREFILL = 8,
  DECODE = 16;
const PEAK = 62;
const sample = (at: number, running = true) => previewHardwareSample(at, running);
const targetsAt = (at: number, running = true) =>
  hardwareTargets(sample(at, running), anatomy, PEAK);
const withGpu = (base: HardwareSample, gpu: Partial<HardwareSample['gpu']>): HardwareSample => ({
  ...base,
  gpu: { ...base.gpu, ...gpu },
});

/** Steps the simulation and the drive together for `seconds` at the 30 fps frame cap. */
function run(
  drive: ReturnType<typeof createHardwareDrive>,
  targets: ReturnType<typeof hardwareTargets> | null,
  seconds: number,
) {
  const engine = createWorkloadEngine({ seed: 7, anatomy, models: 1 });
  let lit!: LitFrame;
  for (let t = 0; t < seconds; t += 1 / 30)
    lit = drive.step(1 / 30, engine.step(1 / 30, { ...IDLE_INPUTS, mode: 'live' }), targets);
  return { lit, simulated: engine.frame };
}

describe('hardware targets', () => {
  it('lights each CPU core by its own load and each L2 by its cluster', () => {
    const measured = sample(DECODE),
      targets = hardwareTargets(measured, anatomy, PEAK);
    expect(targets.cpu).toEqual(measured.cpu.load);
    expect(targets.cpu[4]).toBeGreaterThan(targets.cpu[5]! + 0.3);
    const mean = (ids: number[]) =>
      ids.reduce((sum, id) => sum + measured.cpu.load[id], 0) / ids.length;
    expect(targets.clusters).toEqual(
      anatomy.clusters.map((cluster) => expect.closeTo(mean(cluster.cpus), 9)),
    );
  });

  it('drives the whole GPU from one busy figure and tints Darkbloom’s share', () => {
    const serving = targetsAt(DECODE);
    expect(serving).toMatchObject({ gpu: 0.99, share: 0.97, serving: true });
    expect(serving.clock).toBeCloseTo(1);
    expect(serving.glow).toBeCloseTo(sample(DECODE).gpu.power_w! / PEAK);

    const foreign = withGpu(sample(DECODE), { utilization: 0.8, provider_share: 0.1 });
    expect(hardwareTargets(foreign, anatomy, PEAK)).toMatchObject({
      gpu: 0.8,
      share: 0.1,
      serving: false,
    });
    const stopped = hardwareTargets({ ...foreign, provider: { running: false } }, anatomy, PEAK);
    expect(stopped).toMatchObject({ gpu: 0.8, share: 0, serving: false });
  });

  it('keeps unknown readings null instead of zero', () => {
    const blank: HardwareSample = {
      ...sample(DECODE),
      gpu: {
        utilization: null,
        frequency_mhz: null,
        power_w: null,
        provider_share: null,
        memory_in_use_gb: null,
      },
      ane: { active: null, bandwidth_gbps: null, power_w: null },
      memory: { used_gb: null, wired_gb: null, pressure: null, bandwidth_gbps: null },
    };
    expect(hardwareTargets(blank, anatomy, PEAK)).toMatchObject({
      gpu: null,
      share: null,
      glow: null,
      clock: null,
      traffic: null,
      ane: null,
      other: null,
      phase: null,
      serving: false,
    });
    expect(hardwareReadout(blank, true)).toMatchObject({
      gpu: '—',
      darkbloom: null,
      power: '—',
      clock: '—',
      memory: '—',
    });
    expect(hardwareReadout(sample(DECODE), false)).toMatchObject({ gpu: '—', cpu: '—' });
  });

  it('normalizes DRAM traffic by the chip’s peak bandwidth and flags it as estimated', () => {
    const decode = targetsAt(DECODE),
      idle = targetsAt(IDLE);
    expect(decode.traffic).toBeCloseTo(sample(DECODE).memory.bandwidth_gbps! / 546);
    expect(decode.traffic).toBeGreaterThan(0.8);
    expect(idle.traffic).toBeLessThan(0.05);
    expect(decode.trafficEstimated).toBe(true);
    expect(hardwareReadout(sample(DECODE), true)).toMatchObject({
      gpu: '99%',
      darkbloom: '96%',
      clock: '1,578 MHz',
      memoryEstimated: true,
    });
  });

  it('leaves the Neural Engine dark unless it is actually used', () => {
    expect(targetsAt(DECODE).ane).toBe(0);
    const busy = { ...sample(DECODE), ane: { active: 0.6, bandwidth_gbps: null, power_w: 1 } };
    expect(hardwareTargets(busy, anatomy, PEAK).ane).toBe(0.6);
  });

  it('floors the session peak power by GPU size so idle never glows at full strength', () => {
    expect(sessionPeakPower(0, sample(IDLE), anatomy)).toBe(20);
    expect(sessionPeakPower(20, sample(PREFILL), anatomy)).toBeGreaterThan(55);
    expect(targetsAt(IDLE).glow).toBeLessThan(0.02);
  });

  it('measures memory held by everything else against total RAM', () => {
    const stopped = sample(IDLE, false);
    expect(hardwareTargets(stopped, anatomy, PEAK).other).toBeCloseTo(stopped.memory.used_gb! / 64);
  });
});

describe('hardware phase', () => {
  it('separates compute-bound prefill from bandwidth-bound decode by watts per GB/s', () => {
    expect(hardwarePhase(sample(IDLE))).toBe('idle');
    expect(hardwarePhase(sample(PREFILL))).toBe('prefill');
    expect(hardwarePhase(sample(DECODE))).toBe('decode');
    expect(hardwarePhase(withGpu(sample(DECODE), { power_w: null }))).toBeNull();
  });

  it('lets live provider signals lead and the hardware break ties', () => {
    expect(resolvePhase('decode', 'live', 'prefill', true)).toBe('decode');
    expect(resolvePhase('mixed', 'live', 'prefill', true)).toBe('prefill');
    expect(resolvePhase('ready', 'live', 'decode', true)).toBe('decode');
    expect(resolvePhase('ready', 'live', 'decode', false)).toBe('ready');
    expect(resolvePhase('decode', 'synthetic', 'idle', false)).toBe('ready');
    expect(resolvePhase('stopped', 'stopped', 'decode', false)).toBe('stopped');
    expect(resolvePhase('mixed', 'live', null, true)).toBe('mixed');
  });
});

describe('hardware drive', () => {
  it('uses measured light without manufacturing live phases or traffic', () => {
    const drive = createHardwareDrive(),
      targets = targetsAt(DECODE),
      { lit } = run(drive, targets, 3);
    expect(lit.hardware?.weight).toBeGreaterThan(0.99);
    expect(lit.workload.power).toBeCloseTo(1);
    expect(lit.workload.memoryRead).toBe(0);
    expect(lit.workload.decode).toBe(0);
    expect(lit.workload.phase).toBe('ready');
  });

  it('does not animate unmeasured bandwidth as live traffic', () => {
    const drive = createHardwareDrive();
    const targets = { ...targetsAt(DECODE), traffic: null };
    const { lit } = run(drive, targets, 4);
    expect(lit.workload.memoryRead).toBeLessThan(0.001);
    expect(lit.workload.kvWrite).toBeLessThan(0.001);
  });

  it('eases between 1 Hz samples instead of jumping', () => {
    const drive = createHardwareDrive();
    run(drive, targetsAt(DECODE), 3);
    const { lit } = run(drive, targetsAt(IDLE), 0.2);
    const traffic = lit.hardware!.traffic.value;
    expect(traffic).toBeLessThan(targetsAt(DECODE).traffic!);
    expect(traffic).toBeGreaterThan(targetsAt(IDLE).traffic! + 0.2);
  });

  it('turns measured lights off as soon as the stream goes stale', () => {
    const drive = createHardwareDrive();
    run(drive, targetsAt(DECODE), 3);
    const { lit, simulated } = run(drive, null, 4);
    expect(lit.hardware).toBeNull();
    expect(lit.workload).toBe(simulated);
  });
});

describe('measured light', () => {
  const layout = chipLayout(anatomy, { width: 900, height: 440 });
  const frameAt = (at: number, running = true): RenderFrame => {
    const drive = createHardwareDrive(),
      { lit } = run(drive, targetsAt(at, running), 3);
    return { ...lit, motion: false, pointer: null };
  };

  it('gives every GPU core the same intensity, tinted by Darkbloom’s share', () => {
    const frame = { ...frameAt(DECODE), motion: true },
      levels = layout.tiles
        .filter((tile) => tile.kind === 'gpu' && !tile.filler)
        .map((tile) => {
          const { prefill, decode } = gpuLevel(tile, frame);
          return prefill + decode;
        });
    expect(new Set(levels.map((level) => level.toFixed(6))).size).toBe(1);
    expect(levels[0]).toBeCloseTo(0.99, 2);
    expect(gpuShare(frame)).toBeCloseTo(0.97, 2);
    expect(gpuShare(frameAt(DECODE, false))).toBeCloseTo(0, 2);
  });

  it('lights CPU cores individually', () => {
    const frame = frameAt(DECODE),
      measured = sample(DECODE).cpu.load;
    for (const tile of layout.tiles.filter((tile) => tile.kind === 'performance'))
      expect(cpuLevel(tile, frame)).toBeCloseTo(measured[tile.cpu!], 2);
  });
});
