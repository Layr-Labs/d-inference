import { useCallback, useEffect, useSyncExternalStore } from 'react';
import type { WaitlistEntry } from '../../../shared/waitlists';
import type { BackendState } from '../../useBackend';
import {
  join as joinWaitlist,
  mount,
  need,
  readKey,
  refresh as refreshWaitlists,
  subscribe,
  waitlistsState,
  type WaitlistsRead,
} from './waitlistStore';

// Where the account stands on one feature's waitlist. `open` is true when the feature needs no
// approval here: approved, or a coordinator without that waitlist (it answers that it has none).
// `unsupported`: the runtime has no `waitlists` capability, so the app can't tell.
export type WaitlistStanding =
  | 'loading'
  | 'approved'
  | 'none'
  | 'waitlisted'
  | 'revoked'
  | 'no_waitlist'
  | 'login'
  | 'unavailable'
  | 'unsupported';

const loading: WaitlistsRead = { loading: true };

// The runtime reads `waitlists` and runs `waitlist_join` only with this capability.
export const supportsWaitlists = (backend: BackendState) =>
  !!backend.state?.capabilities?.includes('waitlists');

// Whose answer a read is: `darkbloom waitlist` asks with this Mac's link token, so linking or
// unlinking changes it even when `account_revision` (which follows a signed-in account first)
// stays the same.
const accountOf = (backend: BackendState) =>
  `${backend.state?.account_revision ?? ''}\n${backend.state?.linked ? 'linked' : 'unlinked'}`;

// Every waitlist the coordinator offers, in its order, for this Mac's account. One read serves
// every hook on screen (`waitlistStore.ts`). Nothing is read without the capability, and nothing
// is known before the runtime's first snapshot.
export function useWaitlists(backend: BackendState) {
  const known = !!backend.state;
  const supported = supportsWaitlists(backend);
  const account = accountOf(backend);
  const key = readKey(account, backend.state?.resource_revision ?? '');
  const store = useSyncExternalStore(subscribe, waitlistsState);
  useEffect(() => (supported ? mount() : undefined), [supported]);
  useEffect(() => {
    if (supported) need(key, account);
  }, [supported, key, account]);
  const refresh = useCallback(
    () => (supported ? refreshWaitlists(key, account) : Promise.resolve()),
    [supported, key, account],
  );
  const read = store.read.account === account ? store.read : loading;
  return {
    data: supported ? read.data : undefined,
    error: supported ? read.error : undefined,
    loading: !known || (supported && read.loading),
    supported,
    refresh,
    // Join state, shared by every hook of a feature.
    joining: store.joining,
    problems: store.problems,
    join: (feature: string) => joinWaitlist(feature, key, account),
  };
}

export function useWaitlist(backend: BackendState, feature: string) {
  const list = useWaitlists(backend);
  const entry: WaitlistEntry | undefined = list.data?.data.find((item) => item.feature === feature);
  const standing: WaitlistStanding = list.loading
    ? 'loading'
    : !list.supported
      ? 'unsupported'
      : entry
        ? entry.status
        : list.data?.code === 'login'
          ? 'login'
          : list.data?.code === 'none' || (list.data && !list.data.error)
            ? 'no_waitlist'
            : 'unavailable';
  return {
    entry,
    standing,
    open: standing === 'approved' || standing === 'no_waitlist',
    // Why the list is unavailable: the runtime's words, or why the last read failed.
    error: list.data?.error ?? list.error,
    joining: !!list.joining[feature],
    // Joins the waitlist (or keeps the place), then reads the list again; true when it joined.
    join: () => list.join(feature),
    refresh: list.refresh,
    // The refusal of this feature's last join, in the runtime's words.
    problem: list.problems[feature] as string | undefined,
    // Whether the runtime has the `waitlists` capability.
    supported: list.supported,
  };
}
export type Waitlist = ReturnType<typeof useWaitlist>;
