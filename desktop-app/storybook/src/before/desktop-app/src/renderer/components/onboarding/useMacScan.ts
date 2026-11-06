import { useMemo, useState } from 'react';
import type { BackendState } from '../../useBackend';
import { useReducedMotion } from '../../useReducedMotion';
import { evaluateEligibility, type EligibilityResult } from './eligibility';
import { scanScript } from './scanScript';
import { useScanTimeline } from './useScanTimeline';

const unreachable: BackendState['status']['state'][] = ['missing', 'error', 'incompatible'];

// Each run decides from the first snapshot it sees once active, so a later snapshot never
// changes a verdict mid-scan. Checking again starts a new run from a fresh read.
export function useMacScan(backend: BackendState, active: boolean, onEligible: () => void) {
  const reduced = useReducedMotion();
  const [run, setRun] = useState({ id: 0, reading: false });
  const [scanned, setScanned] = useState<{ run: number; result: EligibilityResult }>();
  const result = scanned?.run === run.id ? scanned.result : undefined;
  if (active && !result && backend.state && !run.reading)
    setScanned({ run: run.id, result: evaluateEligibility(backend.state) });
  const script = useMemo(
    () =>
      active && result
        ? scanScript(result.checks.length, result.verdict === 'eligible', reduced)
        : undefined,
    [active, result, reduced],
  );
  const { frame, finish } = useScanTimeline(script, onEligible);
  return {
    result,
    frame,
    finish,
    settled: !!result && (frame.phase === 'verdict' || frame.phase === 'leaving'),
    blocked: !backend.state && unreachable.includes(backend.status.state),
    async recheck() {
      const id = run.id + 1;
      setRun({ id, reading: true });
      try {
        await backend.refresh();
      } finally {
        setRun((current) => (current.id === id ? { id, reading: false } : current));
      }
    },
  };
}
export type MacScan = ReturnType<typeof useMacScan>;
