import type { WorkloadPhase } from './workload/types';

export const PHASE_TEXT: Record<WorkloadPhase, string> = {
  stopped: 'Stopped',
  ready: 'Ready, weights resident',
  prefill: 'Prefill, reading prompts',
  decode: 'Decode, generating tokens',
  mixed: 'Prefill and decode',
};
