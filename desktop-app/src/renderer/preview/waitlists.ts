import type { WaitlistEntry, Waitlists } from '../../shared/waitlists';
import { previewOperation, previewParam, recordOperation, type FeaturePreview } from './types';

// Development preview of feature waitlists. `&waitlist-cluster=` and `&waitlist-sandbox=` set
// where the account stands (`none`, `waitlisted`, `approved`, `revoked`); `&waitlists=login`,
// `none` or `fail` make the list unavailable for that reason.
const standing = (feature: string, fallback: WaitlistEntry['status']) => {
  const value = previewParam(`waitlist-${feature}`);
  return value === 'none' || value === 'waitlisted' || value === 'approved' || value === 'revoked'
    ? value
    : fallback;
};

const entries: WaitlistEntry[] = [
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
].map((entry) => ({
  ...entry,
  position: entry.status === 'waitlisted' ? (entry.position ?? 12) : null,
  decided_at:
    entry.status === 'approved' || entry.status === 'revoked'
      ? (entry.decided_at ?? '2026-11-03T12:00:00Z')
      : null,
}));

function list(): Waitlists {
  switch (previewParam('waitlists')) {
    case 'login':
      return { data: [], error: 'Link this Mac to your account to see waitlists.', code: 'login' };
    case 'none':
      return { data: [], error: 'This coordinator has no waitlists.', code: 'none' };
    case 'fail':
      return { data: [], error: 'Waitlists are unavailable right now.', code: 'unavailable' };
    default:
      return { data: entries };
  }
}

export const waitlistsPreview: FeaturePreview = {
  resources: () => ({ waitlists: list() }),
  async act(store, action) {
    if (action.action !== 'waitlist_join') return undefined;
    await new Promise((resolve) => setTimeout(resolve, 700));
    const entry = entries.find((item) => item.feature === action.feature);
    if (!entry) throw new Error(`There is no waitlist named “${action.feature}”.`);
    if (entry.status === 'none') {
      entry.status = 'waitlisted';
      entry.position = 41;
      entry.requested_at = new Date().toISOString();
    }
    return recordOperation(store, previewOperation(action));
  },
};
