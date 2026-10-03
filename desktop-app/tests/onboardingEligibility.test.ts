import { describe, expect, it } from 'vitest';
import {
  derivedEligibility,
  evaluateEligibility,
  failedChecks,
} from '../src/renderer/components/onboarding/eligibility';
import { scanScript, scanTiming } from '../src/renderer/components/onboarding/scanScript';
import type { EligibilityCheck } from '../src/shared/eligibility';
import { eightGBMac, models, snapshot } from './onboardingFixtures';

const byID = (checks: EligibilityCheck[]) =>
  Object.fromEntries(checks.map((check) => [check.id, check]));

describe('derived eligibility', () => {
  it('passes Apple silicon with enough memory for the smallest supported model', () => {
    const result = evaluateEligibility(snapshot());
    expect(result.verdict).toBe('eligible');
    expect(result.checks).toEqual([
      { id: 'apple_silicon', label: 'Apple silicon', ok: true, value: 'Apple M4 Max' },
      { id: 'memory', label: 'Unified memory', ok: true, value: '64 GB' },
    ]);
  });

  it('fails memory below the smallest supported model and says what it needs', () => {
    const result = evaluateEligibility(eightGBMac());
    expect(result.verdict).toBe('ineligible');
    expect(failedChecks(result.checks)).toEqual([
      {
        id: 'memory',
        label: 'Unified memory',
        ok: false,
        value: '8 GB',
        detail: 'This Mac has 8 GB of unified memory; the smallest supported model needs 16.4 GB.',
      },
    ]);
  });

  it('compares only with models the runtime supports and reports a need for', () => {
    const checks = derivedEligibility(
      snapshot({
        machine: { ...snapshot().machine, memory_gb: 24 },
        models: [
          { ...models[0], id: 'unsupported', memory_gb: 4, eligible: false },
          { ...models[0], memory_gb: 22.5 },
          { ...models[1] },
        ],
      }),
    ).checks;
    expect(byID(checks).memory.ok).toBe(true);
    const tight = derivedEligibility(
      snapshot({
        machine: { ...snapshot().machine, memory_gb: 16 },
        models: [{ ...models[0], id: 'unsupported', memory_gb: 4, eligible: false }, models[0]],
      }),
    ).checks;
    expect(byID(tight).memory.detail).toBe(
      'This Mac has 16 GB of unified memory; the smallest supported model needs 16.4 GB.',
    );
  });

  it('leaves memory unevaluated when no model reports what it needs', () => {
    const result = evaluateEligibility(
      snapshot({ models: models.map(({ memory_gb: _, ...model }) => model) }),
    );
    expect(result.verdict).toBe('unknown');
    expect(byID(result.checks).memory).toEqual({
      id: 'memory',
      label: 'Unified memory',
      ok: null,
      value: '64 GB',
      detail: 'The runtime didn’t report how much memory its models need.',
    });
  });

  it('never guesses when the runtime could not detect the hardware', () => {
    const result = evaluateEligibility(
      snapshot({ machine: { ...snapshot().machine, chip: 'Unknown hardware', memory_gb: 0 } }),
    );
    expect(result.verdict).toBe('unknown');
    expect(result.checks.map((check) => check.ok)).toEqual([null, null]);
  });

  it('fails a chip that is not Apple silicon', () => {
    const checks = derivedEligibility(
      snapshot({ machine: { ...snapshot().machine, chip: 'Intel Core i9' } }),
    ).checks;
    expect(byID(checks).apple_silicon).toMatchObject({
      ok: false,
      detail: 'Darkbloom needs a Mac with Apple silicon.',
    });
  });
});

describe('reported eligibility', () => {
  const report = (eligible: boolean, ...oks: (boolean | null)[]) =>
    evaluateEligibility(
      snapshot({
        eligibility: {
          eligible,
          checked_at: 1,
          checks: oks.map((ok, index) => ({ id: `check-${index}`, label: 'Check', ok })),
        },
      }),
    );

  it('uses the runtime report instead of deriving checks', () => {
    const checks = [{ id: 'macos', label: 'macOS', ok: true, value: '26.1' }];
    expect(
      evaluateEligibility({
        ...eightGBMac(),
        eligibility: { eligible: true, checked_at: 1, checks },
      }),
    ).toEqual({ verdict: 'eligible', checks });
  });

  it('lets the runtime accept checks it could not evaluate', () => {
    expect(report(true, true, null).verdict).toBe('eligible');
  });

  it('treats any failed check as ineligible, whatever the summary says', () => {
    expect(report(false, true, false).verdict).toBe('ineligible');
    expect(report(true, false).verdict).toBe('ineligible');
  });

  it('is unknown when the runtime declines without a failed check', () => {
    expect(report(false, true, null).verdict).toBe('unknown');
  });
});

describe('scan script', () => {
  const { revealMs, holdMs, exitMs, reducedHoldMs } = scanTiming;

  it('reveals each row before its result, then holds an eligible verdict before advancing', () => {
    const { frames, advanceAt } = scanScript(2, true, false);
    expect(frames).toEqual([
      { at: 0, frame: { revealed: 1, resolved: 0, phase: 'scanning' } },
      { at: 900, frame: { revealed: 1, resolved: 1, phase: 'scanning' } },
      { at: 1500, frame: { revealed: 2, resolved: 1, phase: 'scanning' } },
      { at: 2400, frame: { revealed: 2, resolved: 2, phase: 'scanning' } },
      { at: revealMs, frame: { revealed: 2, resolved: 2, phase: 'verdict' } },
      { at: revealMs + holdMs, frame: { revealed: 2, resolved: 2, phase: 'leaving' } },
    ]);
    expect(advanceAt).toBe(revealMs + holdMs + exitMs);
    expect(advanceAt).toBeGreaterThanOrEqual(4500);
    expect(advanceAt).toBeLessThanOrEqual(5000);
  });

  it('fits any number of rows into the same reveal', () => {
    const { frames } = scanScript(5, false, false);
    const times = frames.map((frame) => frame.at);
    expect(times).toEqual([...times].sort((a, b) => a - b));
    expect(frames.at(-2)?.frame).toEqual({ revealed: 5, resolved: 5, phase: 'scanning' });
    expect(frames.at(-1)).toEqual({
      at: revealMs,
      frame: { revealed: 5, resolved: 5, phase: 'verdict' },
    });
  });

  it('never advances a Mac that is not eligible', () => {
    expect(scanScript(3, false, false).advanceAt).toBeUndefined();
    expect(scanScript(3, false, true).advanceAt).toBeUndefined();
  });

  it('shows everything at once under reduced motion and keeps a reading pause', () => {
    expect(scanScript(4, true, true)).toEqual({
      frames: [{ at: 0, frame: { revealed: 4, resolved: 4, phase: 'verdict' } }],
      advanceAt: reducedHoldMs,
    });
  });

  it('still reaches a verdict with no rows', () => {
    expect(scanScript(0, true, false).frames).toEqual([
      { at: 0, frame: { revealed: 0, resolved: 0, phase: 'scanning' } },
      { at: revealMs, frame: { revealed: 0, resolved: 0, phase: 'verdict' } },
      { at: revealMs + holdMs, frame: { revealed: 0, resolved: 0, phase: 'leaving' } },
    ]);
  });
});
