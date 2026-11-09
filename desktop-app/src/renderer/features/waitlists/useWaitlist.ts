import { useState } from 'react';
import type { WaitlistEntry, Waitlists } from '../../../shared/waitlists';
import type { BackendState } from '../../useBackend';
import { useResource } from '../../data/useResource';

// Where the account stands on one feature's waitlist. `open` is true when the feature needs no
// approval here: approved, or a coordinator without that waitlist (it answers that it has none).
export type WaitlistStanding =
  | 'loading'
  | 'approved'
  | 'none'
  | 'waitlisted'
  | 'revoked'
  | 'no_waitlist'
  | 'login'
  | 'unavailable';

export function useWaitlists(backend: BackendState) {
  return useResource<Waitlists>('waitlists', { refreshKey: backend.state?.resource_revision });
}

export function useWaitlist(backend: BackendState, feature: string) {
  const list = useWaitlists(backend);
  const [joining, setJoining] = useState(false);
  const entry: WaitlistEntry | undefined = list.data?.data.find((item) => item.feature === feature);
  const standing: WaitlistStanding = list.loading
    ? 'loading'
    : entry
      ? entry.status
      : list.data?.code === 'login'
        ? 'login'
        : list.data?.code === 'none' || (list.data && !list.data.error)
          ? 'no_waitlist'
          : 'unavailable';
  const join = async () => {
    setJoining(true);
    try {
      const ok = await backend.act({ action: 'waitlist_join', feature }, true);
      await list.refresh();
      return ok;
    } finally {
      setJoining(false);
    }
  };
  return {
    entry,
    standing,
    open: standing === 'approved' || standing === 'no_waitlist',
    error: list.data?.error ?? list.error,
    joining,
    join,
    refresh: list.refresh,
  };
}
