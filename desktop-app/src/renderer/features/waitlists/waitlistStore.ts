import type { WaitlistEntry, Waitlists } from '../../../shared/waitlists';
import { errorMessage, submitAction, unsupported } from '../../actions';
import { api } from '../../useBackend';

// One read of `waitlists` shared by every hook on screen. Several cards on one page (Early access,
// or a page and its compact card) ask once: hooks that mount while a read is in flight, or after
// it answered on the same page, share it. Like `useResource`, a new page (every hook unmounted,
// then one mounted) starts from loading and reads again; on the page, a new `resource_revision`
// or account, the window becoming visible and `refresh()` read again with the last answer kept on
// screen meanwhile.

export interface WaitlistsRead {
  // The account (`Snapshot.account_revision`) the answer belongs to: another account's waitlists
  // are never shown.
  account?: string;
  data?: Waitlists;
  // Why the last read failed; the last answer stays.
  error?: string;
  loading: boolean;
}

export interface WaitlistsState {
  read: WaitlistsRead;
  // Features whose join is running, and the refusal of a feature's last join.
  joining: Readonly<Record<string, boolean>>;
  problems: Readonly<Record<string, string>>;
}

const statuses = new Set<WaitlistEntry['status']>(['none', 'waitlisted', 'approved', 'revoked']);
const joinTimeoutMs = 2 * 60_000;

let state: WaitlistsState = { read: { loading: true }, joining: {}, problems: {} };
const listeners = new Set<() => void>();
// Reads are numbered; only the latest one's answer is kept.
let request = 0;
let pending: { key: string; visit: number } | undefined;
let answered: { key: string; visit: number } | undefined;
// A visit lasts while at least one hook is mounted.
let visit = 0;
let mounted = 0;
let latest: { key: string; account: string } | undefined;

function publish(next: Partial<WaitlistsState>) {
  state = { ...state, ...next };
  listeners.forEach((listener) => listener());
}

export const waitlistsState = () => state;

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

// The key of an answer: the account it is for and the runtime's 30-second resource clock.
export const readKey = (account: string, revision: string) => `${account}\n${revision}`;

// A runtime answer the screens can trust: entries with an id, a title and a known status.
function normalize(value: unknown): Waitlists {
  const answer = value as Partial<Waitlists> | null;
  if (!answer || typeof answer !== 'object' || !Array.isArray(answer.data))
    return { data: [], error: 'Waitlists are unavailable.', code: 'unavailable' };
  return {
    ...answer,
    data: answer.data.filter(
      (entry): entry is WaitlistEntry =>
        !!entry &&
        typeof entry.feature === 'string' &&
        !!entry.feature &&
        typeof entry.title === 'string' &&
        !!entry.title &&
        statuses.has(entry.status),
    ),
  };
}

function read(key: string, account: string): Promise<void> {
  if (!api) return Promise.resolve();
  const bridge = api;
  const id = ++request;
  const started = { key, visit };
  pending = started;
  return (async () => {
    try {
      const data = normalize(await bridge.read<unknown>('waitlists'));
      if (id === request) publish({ read: { account, data, loading: false } });
    } catch (error) {
      if (id === request)
        publish({
          read: {
            account,
            data: state.read.account === account ? state.read.data : undefined,
            error: errorMessage(error) || 'Waitlists are unavailable.',
            loading: false,
          },
        });
    } finally {
      if (pending === started) {
        pending = undefined;
        answered = started;
      }
    }
  })();
}

function visible() {
  if (!document.hidden && latest) void read(latest.key, latest.account);
}

// A hook on screen. The first after none starts a new visit: its page starts from loading and
// reads afresh. A join's refusal belongs to the page it was shown on; a join still running stays.
export function mount() {
  if (mounted++ === 0) {
    visit++;
    publish({ read: { loading: true }, problems: {} });
    document.addEventListener('visibilitychange', visible);
  }
  return () => {
    if (--mounted === 0) document.removeEventListener('visibilitychange', visible);
  };
}

// A hook needs the answer for `key`: share a read in flight or one answered on this page, or read.
export function need(key: string, account: string) {
  latest = { key, account };
  if (pending?.key === key) {
    pending.visit = visit;
    return;
  }
  if (answered?.key === key && answered.visit === visit && state.read.account === account) return;
  void read(key, account);
}

export function refresh(key: string, account: string) {
  latest = { key, account };
  return read(key, account);
}

// `darkbloom waitlist <feature>` through the runtime: puts the account on the waitlist, or keeps
// its place. A refusal is kept in the runtime's own words; the list is read again either way,
// and the join counts as running until that answer is on screen.
export async function join(feature: string, key: string, account: string): Promise<boolean> {
  if (state.joining[feature]) return false;
  const { [feature]: _, ...problems } = state.problems;
  publish({ joining: { ...state.joining, [feature]: true }, problems });
  let joined = false;
  try {
    if (!api) throw new Error('Open the Darkbloom app to join the waitlist.');
    await submitAction(
      api,
      { action: 'waitlist_join', feature },
      {
        timeoutMs: joinTimeoutMs,
        timeout:
          'Joining is taking longer than expected. Check where you stand before trying again.',
      },
    );
    joined = true;
  } catch (error) {
    publish({
      problems: {
        ...state.problems,
        [feature]: unsupported(error)
          ? 'Joining a waitlist needs a newer Darkbloom CLI.'
          : errorMessage(error) || 'Joining didn’t finish. Try again.',
      },
    });
  }
  try {
    // The screens may have moved on to a newer resource clock (or account) meanwhile.
    const target = latest ?? { key, account };
    await refresh(target.key, target.account);
  } finally {
    const { [feature]: __, ...joining } = state.joining;
    publish({ joining });
  }
  return joined;
}

// Tests start each case with nothing read.
export function resetWaitlists() {
  state = { read: { loading: true }, joining: {}, problems: {} };
  request++;
  pending = undefined;
  answered = undefined;
  latest = undefined;
  listeners.forEach((listener) => listener());
}
