import type { WaitlistEntry, Waitlists } from '../../shared/waitlists';
import { day } from '../features/waitlists/words';
import { previewOperation, previewParam, recordOperation, type FeaturePreview } from './types';

// Development preview of feature waitlists. `&waitlist-cluster=`, `&waitlist-sandbox=` and
// `&waitlist-labs=` set where the account stands (`none`, `waitlisted`, `approved`, `revoked`);
// `&waitlists=login`, `none` or `fail` make the list unavailable for that reason, `more` adds a
// waitlist with no page in the app (it shows its start command), and `unsupported` is a runtime
// without the `waitlists` capability. `&waitlist-join=fail` refuses every join.
const standing = (feature: string, fallback: WaitlistEntry['status']) => {
  const value = previewParam(`waitlist-${feature}`);
  return value === 'none' || value === 'waitlisted' || value === 'approved' || value === 'revoked'
    ? value
    : fallback;
};

const coordinator = 'https://api.darkbloom.dev';

const fixtures: WaitlistEntry[] = [
  {
    feature: 'cluster',
    title: 'Clusters',
    summary: 'Serve one model with two to four of your Macs.',
    start_command: 'darkbloom cluster',
    status: standing('cluster', 'approved'),
    requested_at: '2026-10-29T17:12:00Z',
    decided_at: '2026-11-02T09:30:00Z',
  },
  {
    feature: 'sandbox',
    title: 'Darkbloom Sandbox',
    summary: 'Run Darkbloom Sandbox CI jobs on your Mac.',
    start_command: 'darkbloom sandbox setup',
    status: standing('sandbox', 'waitlisted'),
    position: 3,
    requested_at: '2026-10-29T17:14:00Z',
  },
  // Illustrative only: a waitlist whose feature has no page in the app.
  ...(previewParam('waitlists') === 'more'
    ? [
        {
          feature: 'labs',
          title: 'Darkbloom Labs',
          summary: 'Try new provider features before they ship.',
          start_command: 'darkbloom labs',
          status: standing('labs', 'approved'),
          requested_at: '2026-10-30T15:00:00Z',
          decided_at: '2026-11-04T16:00:00Z',
        },
      ]
    : []),
];
const entries: WaitlistEntry[] = fixtures.map((entry) => ({
  ...entry,
  position: entry.status === 'waitlisted' ? (entry.position ?? 12) : null,
  decided_at:
    entry.status === 'approved' || entry.status === 'revoked'
      ? (entry.decided_at ?? '2026-11-03T12:00:00Z')
      : null,
}));

// Each read returns a copy, as the native API does, so a simulated join changes only later reads.
function list(): Waitlists {
  switch (previewParam('waitlists')) {
    case 'login':
      return {
        data: [],
        error: 'Link this Mac to your Darkbloom account first: darkbloom login',
        code: 'login',
      };
    case 'none':
      return {
        data: [],
        error: `${coordinator} has no waitlists yet, so there is nothing to join there.`,
        code: 'none',
      };
    case 'fail':
      return {
        data: [],
        error: `Could not reach the waitlists at ${coordinator}: The request timed out.`,
        code: 'unavailable',
      };
    default:
      return { data: structuredClone(entries) };
  }
}

// What `darkbloom waitlist <name>` prints after a join, as the operation's message.
function joined(entry: WaitlistEntry) {
  switch (entry.status) {
    case 'waitlisted':
      return `You’re on the ${entry.title} waitlist: #${entry.position} in line (joined ${day(entry.requested_at)}).`;
    case 'approved':
      return `Your account is approved for ${entry.title} since ${day(entry.decided_at)}.`;
    default:
      return `Darkbloom revoked your account’s access to ${entry.title} on ${day(entry.decided_at)}.`;
  }
}

export const waitlistsPreview: FeaturePreview = {
  resources: () => ({ waitlists: list() }),
  snapshot: (snapshot) =>
    previewParam('waitlists') === 'unsupported'
      ? { ...snapshot, capabilities: snapshot.capabilities?.filter((name) => name !== 'waitlists') }
      : {
          ...snapshot,
          // The preview snapshot predates the capability list, which the app reads as Autopilot
          // and the eligibility sign-up being available: keep those when creating the list.
          capabilities: [
            ...(snapshot.capabilities ?? ['autopilot', 'waitlist']).filter(
              (name) => name !== 'waitlists',
            ),
            'waitlists',
          ],
        },
  async act(store, action) {
    if (action.action !== 'waitlist_join') return undefined;
    await new Promise((resolve) => setTimeout(resolve, 700));
    const entry = entries.find((item) => item.feature === action.feature);
    if (!entry) throw new Error(`Unknown waitlist '${action.feature}'.`);
    if (previewParam('waitlist-join') === 'fail')
      return recordOperation(
        store,
        previewOperation(
          action,
          'failed',
          `Could not reach the ${entry.title} waitlist at ${coordinator}: The request timed out.`,
        ),
      );
    if (entry.status === 'none') {
      entry.status = 'waitlisted';
      entry.position = 41;
      entry.requested_at = new Date().toISOString();
    }
    // A revoked account's join fails, as the CLI's does.
    return recordOperation(
      store,
      previewOperation(action, entry.status === 'revoked' ? 'failed' : 'succeeded', joined(entry)),
    );
  },
};
