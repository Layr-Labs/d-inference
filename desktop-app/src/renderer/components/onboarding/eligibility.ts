import type { NativeModel, Snapshot } from '../../../shared/contracts';
import type { Eligibility, EligibilityCheck } from '../../../shared/eligibility';
import { gigabytes } from '../../models/facts';

export type Verdict = 'eligible' | 'ineligible' | 'unknown';
export interface EligibilityResult {
  verdict: Verdict;
  checks: EligibilityCheck[];
}

export function evaluateEligibility(snapshot: Snapshot): EligibilityResult {
  const report = snapshot.eligibility ?? derivedEligibility(snapshot);
  return { verdict: verdictOf(report), checks: report.checks };
}

export const failedChecks = (checks: EligibilityCheck[]) =>
  checks.filter((check) => check.ok === false);

function verdictOf({ eligible, checks }: Eligibility): Verdict {
  if (failedChecks(checks).length) return 'ineligible';
  return eligible ? 'eligible' : 'unknown';
}

// A runtime that failed to detect its hardware reports zero memory, so both checks stay
// unevaluated rather than guessed. Memory is compared only with what the snapshot's own
// models say they need; the provider's load-time admission is not reimplemented here. The
// runtime measures memory only for downloaded models, so a model not yet on this Mac (every
// model on a fresh install) needs its catalog size, as the runtime's own fit check assumes.
// Models the runtime accepts set the bar; when it accepts none, memory explains that only if
// every reported model needs more than this Mac has.
export function derivedEligibility({ machine, models, observed_at }: Snapshot): Eligibility {
  const detected = machine.memory_gb > 0;
  const need = (model: NativeModel) => model.memory_gb || model.size_gb;
  const sized = models.filter((model) => need(model) > 0);
  const accepted = sized.filter((model) => model.eligible);
  const compared = accepted.length
    ? accepted
    : sized.every((model) => need(model) > machine.memory_gb)
      ? sized
      : [];
  const checks = [
    appleSiliconCheck(detected ? machine.chip : undefined),
    memoryCheck(
      detected ? machine.memory_gb : undefined,
      compared.length ? Math.min(...compared.map(need)) : undefined,
    ),
  ];
  return { eligible: checks.every((check) => check.ok), checked_at: observed_at, checks };
}

function appleSiliconCheck(chip?: string): EligibilityCheck {
  const check = { id: 'apple_silicon', label: 'Apple silicon' };
  if (!chip)
    return { ...check, ok: null, detail: 'The runtime couldn’t identify this Mac’s chip.' };
  return /^Apple\b/.test(chip)
    ? { ...check, ok: true, value: chip }
    : { ...check, ok: false, value: chip, detail: 'Darkbloom needs a Mac with Apple silicon.' };
}

function memoryCheck(total?: number, smallest?: number): EligibilityCheck {
  const check = { id: 'memory', label: 'Unified memory' };
  if (!total) return { ...check, ok: null, detail: 'The runtime couldn’t read this Mac’s memory.' };
  const value = gigabytes(total);
  if (!smallest)
    return {
      ...check,
      ok: null,
      value,
      detail: 'The runtime didn’t report how much memory its models need.',
    };
  return total >= smallest
    ? { ...check, ok: true, value }
    : {
        ...check,
        ok: false,
        value,
        detail: `This Mac has ${value} of unified memory; the smallest supported model needs ${gigabytes(smallest)}.`,
      };
}
