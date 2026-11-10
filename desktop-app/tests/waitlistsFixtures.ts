import type { Operation, Snapshot } from '../src/shared/contracts';
import type { WaitlistEntry, Waitlists } from '../src/shared/waitlists';
import type { BackendState } from '../src/renderer/useBackend';
import { backendWith, snapshot } from './onboardingFixtures';

// Where an account stands on each waitlist, as `darkbloom waitlist --json` answers it. Times are
// at midday UTC so the day is the same in every test time zone.
export const cluster: WaitlistEntry = {
  feature: 'cluster',
  title: 'Clusters',
  summary: 'Serve one model with two to four of your Macs.',
  start_command: 'darkbloom cluster',
  status: 'approved',
  requested_at: '2026-10-29T12:00:00Z',
  decided_at: '2026-11-02T12:00:00Z',
};
export const sandbox: WaitlistEntry = {
  feature: 'sandbox',
  title: 'Darkbloom Sandbox',
  summary: 'Run Darkbloom Sandbox CI jobs on your Mac.',
  start_command: 'darkbloom sandbox setup',
  status: 'waitlisted',
  position: 3,
  requested_at: '2026-10-29T12:00:00Z',
};
// A waitlist whose feature has no page in the app.
export const labs: WaitlistEntry = {
  feature: 'labs',
  title: 'Darkbloom Labs',
  summary: 'Try new provider features before they ship.',
  start_command: 'darkbloom labs',
  status: 'approved',
  requested_at: '2026-10-30T12:00:00Z',
  decided_at: '2026-11-04T12:00:00Z',
};

export const list = (...data: WaitlistEntry[]): Waitlists => ({ data });

// The day as the app and the CLI write it, in the test's locale.
export const day = (iso: string) =>
  new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });

// A connected Mac whose runtime offers waitlists.
export const waitlistSnapshot = (overrides: Partial<Snapshot> = {}) =>
  snapshot({
    capabilities: ['account-signin', 'autopilot', 'waitlists'],
    account_revision: 'account-1',
    resource_revision: '1000',
    ...overrides,
  });

export const waitlistBackend = (
  overrides: Partial<Snapshot> = {},
  backend: Partial<BackendState> = {},
) => backendWith(waitlistSnapshot(overrides), backend);

export const joinOperation = (state: Operation['state'], message = ''): Operation => ({
  id: 'join-1',
  action: 'waitlist_join',
  state,
  started_at: 1_790_000_000,
  finished_at: state === 'running' ? undefined : 1_790_000_001,
  message,
  cancellable: false,
});

// A promise and the function that settles it, for reads that answer when a test says so.
export function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((done, fail) => {
    resolve = done;
    reject = fail;
  });
  return { promise, resolve, reject };
}
