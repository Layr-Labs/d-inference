import type { Snapshot } from '../../../shared/contracts';
import type { Eligibility, EligibilityCheck } from '../../../shared/eligibility';
import { supportsNewProviders } from '../../../shared/macos';
import { gigabytes } from '../../models/facts';

export type Verdict = 'eligible' | 'ineligible' | 'unknown';
export interface EligibilityResult {
  verdict: Verdict;
  checks: EligibilityCheck[];
}

// `macosVersion` comes from the main process. When the report has no macOS check of its own, one
// is added from it; an unknown version adds none.
export function evaluateEligibility(snapshot: Snapshot, macosVersion?: string): EligibilityResult {
  const report = withMacOSCheck(snapshot.eligibility ?? derivedEligibility(snapshot), macosVersion);
  return { verdict: verdictOf(report), checks: report.checks };
}

function withMacOSCheck(report: Eligibility, version?: string): Eligibility {
  if (!version || report.checks.some((check) => check.id === 'macos')) return report;
  const check = macosCheck(version);
  return { ...report, eligible: report.eligible && !!check.ok, checks: [...report.checks, check] };
}

// New providers need macOS 27 or later.
export function macosCheck(version: string): EligibilityCheck {
  const check = { id: 'macos', label: 'macOS', value: version };
  return supportsNewProviders(version)
    ? { ...check, ok: true }
    : {
        ...check,
        ok: false,
        detail:
          'Darkbloom needs macOS 27 or later for new providers. Update macOS in Software Update.',
      };
}

export const failedChecks = (checks: EligibilityCheck[]) =>
  checks.filter((check) => check.ok === false);

function verdictOf({ eligible, checks }: Eligibility): Verdict {
  if (failedChecks(checks).length) return 'ineligible';
  return eligible ? 'eligible' : 'unknown';
}

// A runtime that failed to detect its hardware reports zero memory, so both checks stay
// unevaluated rather than guessed. Memory is compared only with what the snapshot's own
// models say they need; the provider's load-time admission is not reimplemented here.
export function derivedEligibility({ machine, models, observed_at }: Snapshot): Eligibility {
  const detected = machine.memory_gb > 0;
  const needs = models.flatMap((model) =>
    model.eligible && model.memory_gb ? [model.memory_gb] : [],
  );
  const checks = [
    appleSiliconCheck(detected ? machine.chip : undefined),
    memoryCheck(
      detected ? machine.memory_gb : undefined,
      needs.length ? Math.min(...needs) : undefined,
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
