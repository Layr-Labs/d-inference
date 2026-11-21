import type { ChipAnatomy } from '../anatomy';
import { clamp } from '../geometry';
import { seeded } from '../random';
import { createArrivals } from './arrivals';
import { chipCapability } from './capability';
import { distribute } from './distribute';
import { pickModel, sampleSequence, type Sequence } from './sequence';
import { IDLE_INPUTS, type WorkloadFrame, type WorkloadInputs, type WorkloadPhase } from './types';

const STEP = 1 / 60,
  MAX_ELAPSED = 0.25,
  CONCURRENCY = 8,
  LIVE_SEQUENCE_CAP = 40,
  KV_SCALE_TOKENS = 9000,
  RECONCILE_EVERY = 0.09;

export interface WorkloadEngine {
  /** Advances by `elapsed` seconds in fixed sub-steps, so a seed replays identically. */
  step(elapsed: number, inputs: WorkloadInputs): WorkloadFrame;
  readonly frame: WorkloadFrame;
}
export interface WorkloadOptions {
  seed: number;
  anatomy: ChipAnatomy;
  /** Number of loaded models; weights glow only when there is at least one. */
  models: number;
  /** Seconds of synthetic traffic simulated up front so the first frame is mid-workload. */
  warmup?: number;
}

const approach = (value: number, target: number, attack: number, release: number) =>
  value + (target - value) * (1 - Math.exp(-STEP / (target > value ? attack : release)));
const saturate = (value: number, scale: number) => 1 - Math.exp(-Math.max(0, value) / scale);

export function createWorkloadEngine({
  seed,
  anatomy,
  models: loaded,
  warmup = 0,
}: WorkloadOptions): WorkloadEngine {
  const random = seeded(seed),
    capability = chipCapability(anatomy),
    models = Math.max(1, loaded),
    arrive = createArrivals(random, capability, warmup);
  const level = {
    power: 0,
    resident: 0,
    prefill: 0,
    decode: 0,
    memoryRead: 0,
    kvFill: 0,
    kvWrite: 0,
    cpu: 0,
    tokensPerSecond: 0,
  };
  const decodeByModel: number[] = Array(models).fill(0);
  let sequences: Sequence[] = [],
    time = 0,
    carry = 0,
    lastArrival = -1e6,
    lastPrefill = -1e6,
    lastFlood = -1e6,
    cpuBurst = 0,
    reconcileIn = 0,
    observedTps = 0,
    stepPhase = 0,
    steps = 0,
    running = 0,
    waiting = 0,
    phase: WorkloadPhase = 'stopped',
    mode = IDLE_INPUTS.mode;

  const reconcile = (inputs: WorkloadInputs) => {
    reconcileIn -= STEP;
    if (reconcileIn > 0) return;
    const target = Math.min(LIVE_SEQUENCE_CAP, Math.max(0, Math.round(inputs.running))),
      desired = distribute(target, inputs.runningByModel, models),
      counts: number[] = Array(models).fill(0);
    for (const seq of sequences) counts[seq.model]++;
    const gaps = desired.map((want, m) => want - counts[m]);
    const short = gaps.indexOf(Math.max(...gaps)),
      over = gaps.indexOf(Math.min(...gaps));
    if (gaps[short] > 0) {
      const median =
        inputs.requestsPerSecond > 0
          ? clamp(inputs.tokensPerSecond / inputs.requestsPerSecond, 40, 4000)
          : 220;
      sequences.push({ ...sampleSequence(random, short, median), stage: 'prefill' });
      lastArrival = time;
      cpuBurst = 1;
      reconcileIn = RECONCILE_EVERY;
    } else if (gaps[over] < 0) {
      let victim = -1;
      sequences.forEach((seq, i) => {
        const progress = seq.prefilled + seq.generated;
        if (
          seq.model === over &&
          (victim < 0 || progress > sequences[victim].prefilled + sequences[victim].generated)
        )
          victim = i;
      });
      sequences.splice(victim, 1);
      reconcileIn = RECONCILE_EVERY;
    }
  };

  const tick = (inputs: WorkloadInputs) => {
    time += STEP;
    const live = inputs.mode === 'live';
    if (inputs.mode === 'synthetic') {
      if (arrive(time, STEP)) {
        sequences.push(sampleSequence(random, pickModel(random, models), 220));
        lastArrival = time;
      }
      let active = sequences.filter((seq) => seq.stage !== 'waiting').length;
      for (const seq of sequences) {
        if (active >= CONCURRENCY) break;
        if (seq.stage !== 'waiting') continue;
        seq.stage = 'prefill';
        cpuBurst = 1;
        active++;
      }
    } else if (live) reconcile(inputs);
    else sequences = [];

    // Prefill is compute-bound: prompts are processed in order at the chip's full rate.
    let budget = capability.prefillTokensPerSecond * STEP,
      written = 0;
    for (const seq of sequences) {
      if (budget <= 0) break;
      if (seq.stage !== 'prefill') continue;
      if (seq.prefilled === 0) lastPrefill = time;
      const take = Math.min(budget, seq.prompt - seq.prefilled);
      seq.prefilled += take;
      budget -= take;
      written += take;
      if (seq.prefilled >= seq.prompt) seq.stage = 'decode';
    }
    const prefilling = written > 0;
    if (prefilling && level.prefill < 0.25) lastFlood = time;

    // Decode is bandwidth-bound: one token per sequence per step, batched.
    observedTps = approach(observedTps, inputs.tokensPerSecond, 0.5, 0.5);
    const decoding = sequences.filter((seq) => seq.stage === 'decode');
    const perSequence = !decoding.length
      ? 0
      : live
        ? Math.min(capability.decodeTokensPerSecond * 2, observedTps / decoding.length)
        : (capability.decodeTokensPerSecond / (1 + 0.035 * (decoding.length - 1))) *
          (prefilling ? 0.6 : 1);
    const perModel: number[] = Array(models).fill(0);
    for (const seq of decoding) {
      seq.generated += perSequence * STEP;
      perModel[seq.model] += perSequence;
    }
    written += perSequence * STEP * decoding.length;
    sequences = sequences.filter((seq) => seq.stage !== 'decode' || seq.generated < seq.output);

    const tps = perSequence * decoding.length,
      streaming = tps > 0.5 ? decoding.length : 0,
      kvTokens = sequences.reduce((sum, seq) => sum + seq.prefilled + seq.generated, 0);
    const decodeTarget = streaming ? saturate(tps, capability.decodeTokensPerSecond * 1.8) : 0;
    const readTarget = clamp(
      (streaming ? 0.5 + 0.45 * saturate(streaming, 3) : 0) +
        (prefilling ? 0.3 : 0) +
        (streaming || prefilling ? 0.1 * level.kvFill : 0),
    );
    cpuBurst *= Math.exp(-STEP / 0.22);
    const powered = inputs.mode !== 'stopped';

    level.power = approach(level.power, powered ? 1 : 0, 0.45, 0.8);
    level.resident = approach(level.resident, powered && loaded > 0 ? 1 : 0, 0.6, 0.9);
    level.prefill = approach(level.prefill, prefilling ? 1 : 0, 0.05, 0.35);
    level.decode = approach(level.decode, decodeTarget, 0.22, 0.6);
    level.memoryRead = approach(level.memoryRead, readTarget, 0.1, 0.45);
    level.kvFill = approach(level.kvFill, saturate(kvTokens, KV_SCALE_TOKENS), 0.2, 0.55);
    level.kvWrite = approach(
      level.kvWrite,
      clamp(written / (capability.prefillTokensPerSecond * STEP)),
      0.05,
      0.3,
    );
    level.cpu = approach(
      level.cpu,
      Math.max(cpuBurst * 0.9, streaming ? 0.06 + 0.1 * decodeTarget : 0),
      0.03,
      0.22,
    );
    level.tokensPerSecond = approach(level.tokensPerSecond, live ? observedTps : tps, 0.4, 0.45);
    perModel.forEach((rate, m) => {
      const target = streaming ? saturate(rate, capability.decodeTokensPerSecond * 1.8) : 0;
      decodeByModel[m] = approach(decodeByModel[m], target, 0.22, 0.6);
    });

    if (level.decode > 0.03 || stepPhase > 0) {
      stepPhase += (0.75 + 1.5 * level.decode) * STEP;
      if (stepPhase >= 1) {
        steps++;
        stepPhase = level.decode > 0.03 ? stepPhase - 1 : 0;
      }
    }
    running = live ? inputs.running : sequences.filter((seq) => seq.stage !== 'waiting').length;
    waiting = live ? inputs.waiting : sequences.length - running;
    phase = !powered
      ? 'stopped'
      : level.prefill > 0.3
        ? level.decode > 0.12
          ? 'mixed'
          : 'prefill'
        : level.decode > 0.12
          ? 'decode'
          : 'ready';
    mode = inputs.mode;
  };

  const compose = (): WorkloadFrame => ({
    time,
    mode,
    phase,
    ...level,
    decodeByModel: decodeByModel.slice(),
    running,
    waiting,
    stepPhase,
    steps,
    sinceArrival: time - lastArrival,
    sincePrefill: time - lastPrefill,
    sinceFlood: time - lastFlood,
  });

  const synthetic: WorkloadInputs = { ...IDLE_INPUTS, mode: 'synthetic' };
  for (let i = 0; i < Math.round(warmup / STEP); i++) tick(synthetic);
  let frame = compose();
  return {
    step(elapsed, inputs) {
      carry += clamp(elapsed, 0, MAX_ELAPSED);
      while (carry >= STEP) {
        carry -= STEP;
        tick(inputs);
      }
      frame = compose();
      return frame;
    },
    get frame() {
      return frame;
    },
  };
}
