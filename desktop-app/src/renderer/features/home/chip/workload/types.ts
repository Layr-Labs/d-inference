export type WorkloadMode = 'stopped' | 'idle' | 'synthetic' | 'live';
export type WorkloadPhase = 'stopped' | 'ready' | 'prefill' | 'decode' | 'mixed';

/** What drives the simulation: synthetic arrivals, or targets observed from the runtime. */
export interface WorkloadInputs {
  mode: WorkloadMode;
  running: number;
  waiting: number;
  tokensPerSecond: number;
  requestsPerSecond: number;
  /** Running requests per loaded model, in loaded-model order. */
  runningByModel: number[];
}

/** Smoothed per-frame activity; every level is in [0, 1]. */
export interface WorkloadFrame {
  time: number;
  mode: WorkloadMode;
  phase: WorkloadPhase;
  /** 0 when the provider is stopped (chip dark), 1 when powered. */
  power: number;
  /** Weights resident in unified memory. */
  resident: number;
  /** Compute-bound prompt processing on the GPU. */
  prefill: number;
  /** Bandwidth-bound token generation. */
  decode: number;
  decodeByModel: number[];
  /** Unified-memory read bandwidth in use. */
  memoryRead: number;
  /** Share of the KV-cache region holding context. */
  kvFill: number;
  /** Rate at which new KV entries are written. */
  kvWrite: number;
  cpu: number;
  tokensPerSecond: number;
  running: number;
  waiting: number;
  /** Position within the current illustrative decode step, in [0, 1). */
  stepPhase: number;
  steps: number;
  sinceArrival: number;
  /** Seconds since the latest prompt started prefilling. */
  sincePrefill: number;
  /** Seconds since the GPU went from not prefilling to prefilling. */
  sinceFlood: number;
}

export const IDLE_INPUTS: WorkloadInputs = {
  mode: 'idle',
  running: 0,
  waiting: 0,
  tokensPerSecond: 0,
  requestsPerSecond: 0,
  runningByModel: [],
};
