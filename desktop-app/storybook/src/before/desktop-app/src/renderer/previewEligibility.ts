import type { Snapshot } from '../shared/contracts';
import type { EligibilityCheck } from '../shared/eligibility';

// Development preview only. `?preview&onboarding=eligible|ineligible|unknown` opens onboarding
// on that scan result; `&waitlist=fail` rejects sign-ups the way a runtime without the
// action does.
const scenarios = ['eligible', 'ineligible', 'unknown'] as const;
export type OnboardingScenario = (typeof scenarios)[number];

const params = new URLSearchParams(globalThis.location?.search);
export const onboardingScenario: OnboardingScenario | undefined =
  import.meta.env.DEV && params.has('preview')
    ? scenarios.find((scenario) => scenario === params.get('onboarding'))
    : undefined;

function freshInstall(snapshot: Snapshot): Snapshot {
  return {
    ...snapshot,
    state: 'stopped',
    readiness: 'Ready when you are',
    machine: { ...snapshot.machine, status: 'stopped', models: [] },
    models: snapshot.models.map(({ memory_gb: _, ...model }) => ({
      ...model,
      downloaded: false,
      serving: false,
      loaded: false,
    })),
    endpoint: undefined,
  };
}

function reported(snapshot: Snapshot, checks: EligibilityCheck[]): Snapshot {
  return {
    ...snapshot,
    eligibility: {
      eligible: checks.every((check) => check.ok),
      checked_at: snapshot.observed_at,
      checks,
    },
  };
}

export function withOnboardingScenario(
  snapshot: Snapshot,
  scenario = onboardingScenario,
): Snapshot {
  if (scenario === 'eligible')
    return reported(snapshot, [
      { id: 'apple_silicon', label: 'Apple silicon', ok: true, value: snapshot.machine.chip },
      {
        id: 'memory',
        label: 'Unified memory',
        ok: true,
        value: `${snapshot.machine.memory_gb} GB`,
      },
      { id: 'macos', label: 'macOS', ok: true, value: '26.1' },
      { id: 'storage', label: 'Free storage', ok: true, value: '412 GB' },
      { id: 'security', label: 'Security', ok: true, value: 'SIP and Secure Boot on' },
    ]);
  if (scenario === 'ineligible') {
    const air = freshInstall(snapshot);
    return reported(
      {
        ...air,
        linked: false,
        machine: { ...air.machine, name: 'MacBook Air', chip: 'Apple M1', memory_gb: 8 },
        memory: { total_gb: 8 },
        settings: { ...air.settings, name: 'MacBook Air' },
      },
      [
        { id: 'apple_silicon', label: 'Apple silicon', ok: true, value: 'Apple M1' },
        {
          id: 'memory',
          label: 'Unified memory',
          ok: false,
          value: '8 GB',
          detail:
            'This Mac has 8 GB of unified memory; the smallest model on Darkbloom needs 16 GB.',
        },
        { id: 'macos', label: 'macOS', ok: true, value: '15.6' },
        { id: 'storage', label: 'Free storage', ok: true, value: '96 GB' },
        { id: 'security', label: 'Security', ok: true, value: 'SIP and Secure Boot on' },
      ],
    );
  }
  // An older runtime on a fresh install: no eligibility report and no downloaded model to
  // say how much memory a model needs.
  if (scenario === 'unknown') return freshInstall(snapshot);
  return snapshot;
}

export async function previewWaitlist() {
  await new Promise((resolve) => setTimeout(resolve, 700));
  if (params.get('waitlist') === 'fail') throw new Error('Unknown action');
}
