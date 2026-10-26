import type { Snapshot } from '../shared/contracts';
import type { EligibilityCheck } from '../shared/eligibility';
import { macosMajor } from '../shared/macos';
import { macosCheck } from './components/onboarding/eligibility';

// Development preview only. `?preview&onboarding=eligible|ineligible|unknown` opens onboarding
// on that scan result; `&waitlist=fail` rejects sign-ups the way a runtime without the
// action does; `&macos=26.5` reports that macOS version instead of 27.0.
const scenarios = ['eligible', 'ineligible', 'unknown'] as const;
export type OnboardingScenario = (typeof scenarios)[number];

const params = new URLSearchParams(globalThis.location?.search);
export const onboardingScenario: OnboardingScenario | undefined =
  import.meta.env.DEV && params.has('preview')
    ? scenarios.find((scenario) => scenario === params.get('onboarding'))
    : undefined;

// Read when asked, so a test can change the address between calls.
export function previewMacOSVersion() {
  const version = new URLSearchParams(globalThis.location?.search).get('macos');
  return version && macosMajor(version) !== undefined ? version : '27.0';
}

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
      macosCheck(previewMacOSVersion()),
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
        macosCheck(previewMacOSVersion()),
        { id: 'storage', label: 'Free storage', ok: true, value: '96 GB' },
        { id: 'security', label: 'Security', ok: true, value: 'SIP and Secure Boot on' },
      ],
    );
  }
  // A fresh install whose runtime has not loaded the model catalog yet: no eligibility report
  // and no model to say how much memory it needs.
  if (scenario === 'unknown') return { ...freshInstall(snapshot), models: [] };
  return snapshot;
}

export async function previewWaitlist() {
  await new Promise((resolve) => setTimeout(resolve, 700));
  if (params.get('waitlist') === 'fail') throw new Error('Unknown action');
}
