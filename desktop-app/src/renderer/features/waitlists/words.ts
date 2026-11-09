import type { Route } from '../../../shared/contracts';
import type { WaitlistEntry } from '../../../shared/waitlists';

// The waitlists whose feature has a page in this app: Open goes there once approved. Any other
// waitlist shows its start command instead.
export const featurePages: Readonly<Record<string, Route>> = {
  cluster: 'cluster',
  sandbox: 'sandboxes',
};

// Coordinator text shown as the CLI prints it (`FeatureWaitlistView.printable`): a control,
// format or line-separator character becomes U+FFFD, so a title, summary, command or refusal
// cannot reorder or hide what the screen shows. A message keeps its line breaks.
const unprintable = /[\p{Cc}\p{Cf}\u2028\u2029]/gu;
export const printable = (text: string) => text.replace(unprintable, '\uFFFD');
export const printableLines = (text: string) =>
  text.replace(/\r\n?/g, '\n').split('\n').map(printable).join('\n');

// The day of an ISO 8601 time as the CLI writes it ("Oct 29, 2026"); undefined when absent or
// unreadable.
export function day(iso?: string | null) {
  if (!iso) return undefined;
  const date = new Date(iso);
  return Number.isNaN(date.getTime())
    ? undefined
    : date.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}

// A waitlist's start command, trimmed; undefined when the coordinator gives none.
export const startCommand = (entry: WaitlistEntry) =>
  entry.start_command?.trim() ? printable(entry.start_command.trim()) : undefined;

export const reviewOrder = 'Darkbloom reviews accounts in the order they joined.';
export const revokedForGood = 'Joining again doesn’t restore it.';

// Where the account stands, as one line of the list (`darkbloom waitlist`): `Not joined`,
// `#3 in line · joined Oct 29, 2026`, `Approved since Nov 2, 2026`, `Revoked on Nov 3, 2026`.
// `place: false` leaves out the place in line, for a card that shows it on its own.
export function standingLine(entry: WaitlistEntry, { place = true } = {}) {
  const joined = day(entry.requested_at);
  const decided = day(entry.decided_at);
  switch (entry.status) {
    case 'none':
      return 'Not joined';
    case 'waitlisted': {
      const position = place && entry.position != null ? `#${entry.position} in line` : undefined;
      const since = joined && `joined ${joined}`;
      if (position) return since ? `${position} · ${since}` : position;
      if (entry.position != null) return since ? `Joined ${joined}` : 'On the waitlist';
      return since ? `On the waitlist · ${since}` : 'On the waitlist';
    }
    case 'approved':
      return decided ? `Approved since ${decided}` : 'Approved';
    case 'revoked':
      return decided ? `Revoked on ${decided}` : 'Revoked';
  }
}

// Where the account stands, as the CLI says it after `darkbloom waitlist <name>`: a sentence that
// names the waitlist, then what it means. For a short notice above the feature's own page.
export function standingSentence(entry: WaitlistEntry): { line: string; detail?: string } {
  const title = printable(entry.title);
  const joined = day(entry.requested_at);
  const decided = day(entry.decided_at);
  switch (entry.status) {
    case 'none':
      return { line: `You’re not on the ${title} waitlist.` };
    case 'waitlisted':
      return {
        line:
          entry.position != null
            ? `You’re on the ${title} waitlist: #${entry.position} in line.`
            : `You’re on the ${title} waitlist.`,
        detail: joined ? `Joined ${joined}. ${reviewOrder}` : reviewOrder,
      };
    case 'approved':
      return {
        line: decided
          ? `Your account is approved for ${title} since ${decided}.`
          : `Your account is approved for ${title}.`,
      };
    case 'revoked':
      return {
        line: decided
          ? `Darkbloom revoked your account’s access to ${title} on ${decided}.`
          : `Darkbloom revoked your account’s access to ${title}.`,
        detail: revokedForGood,
      };
  }
}
