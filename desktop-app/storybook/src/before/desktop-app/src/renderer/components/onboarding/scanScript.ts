// About five seconds from the first fact on screen to the next step, so people can take in
// what was found: the reveal, then the eligible verdict held, then the hand-off.
export const scanTiming = {
  revealMs: 3000,
  holdMs: 1000,
  exitMs: 700,
  // Reduced motion shows every result at once, so the whole pause is reading time.
  reducedHoldMs: 4000,
};

export interface ScanFrame {
  // Rows whose observed value is shown, and rows whose result is shown.
  revealed: number;
  resolved: number;
  phase: 'waiting' | 'scanning' | 'verdict' | 'leaving';
}
export interface ScanScript {
  frames: { at: number; frame: ScanFrame }[];
  // Present only for an eligible Mac: when the scan hands off to the next step.
  advanceAt?: number;
}

// Each row's result lands this far into its slot, after its value appears.
const resolveFraction = 0.6;

export function scanScript(rows: number, eligible: boolean, reduced: boolean): ScanScript {
  const { revealMs, holdMs, exitMs, reducedHoldMs } = scanTiming;
  const verdict: ScanFrame = { revealed: rows, resolved: rows, phase: 'verdict' };
  if (reduced)
    return { frames: [{ at: 0, frame: verdict }], advanceAt: eligible ? reducedHoldMs : undefined };
  const slot = revealMs / Math.max(rows, 1);
  const frames: ScanScript['frames'] = [
    { at: 0, frame: { revealed: Math.min(rows, 1), resolved: 0, phase: 'scanning' } },
  ];
  for (let row = 1; row <= rows; row++) {
    frames.push({
      at: (row - 1 + resolveFraction) * slot,
      frame: { revealed: row, resolved: row, phase: 'scanning' },
    });
    if (row < rows)
      frames.push({
        at: row * slot,
        frame: { revealed: row + 1, resolved: row, phase: 'scanning' },
      });
  }
  frames.push({ at: revealMs, frame: verdict });
  if (!eligible) return { frames };
  frames.push({ at: revealMs + holdMs, frame: { ...verdict, phase: 'leaving' } });
  return { frames, advanceAt: revealMs + holdMs + exitMs };
}
