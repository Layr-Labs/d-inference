import { useCallback, useEffect, useId, useRef, useState } from 'react';
import {
  ArrowRight,
  Ban,
  Boxes,
  Check,
  CircleCheck,
  CircleDashed,
  Clock,
  Copy,
  LoaderCircle,
  Network,
  Ticket,
  type LucideIcon,
} from 'lucide-react';
import type { WaitlistEntry } from '../../../shared/waitlists';
import { Button } from '../../components/UI';
import { api, type BackendState } from '../../useBackend';
import { useWaitlist, type Waitlist } from './useWaitlist';
import { NeedsNewerCLI, WaitlistProblem } from './WaitlistProblem';
import {
  printable,
  printableLines,
  reviewOrder,
  revokedForGood,
  standingLine,
  standingSentence,
  startCommand,
} from './words';
import styles from './waitlists.module.css';

const featureIcons: Readonly<Record<string, LucideIcon>> = { cluster: Network, sandbox: Boxes };
const statusIcons: Record<WaitlistEntry['status'], LucideIcon> = {
  none: CircleDashed,
  waitlisted: Clock,
  approved: CircleCheck,
  revoked: Ban,
};
const tone = (status: WaitlistEntry['status']) =>
  status === 'approved' ? 'positive' : status === 'revoked' ? 'muted' : undefined;

// One feature's waitlist and where the account stands, in the CLI's words, with what to do next:
// Join the waitlist, or Open the feature once approved (`onOpen`, when it has a page in this app;
// otherwise its start command, to copy). `compact` is the one-row notice above the feature's own
// page: it shows nothing while loading or once the feature is open (approved, or no waitlist).
export function WaitlistCard({
  feature,
  backend,
  compact = false,
  onOpen,
}: {
  feature: string;
  backend: BackendState;
  compact?: boolean;
  onOpen?: () => void;
}) {
  const waitlist = useWaitlist(backend, feature);
  const { entry, standing } = waitlist;
  const standingRef = useStandingFocus(entry?.status);
  if (standing === 'unsupported') return <NeedsNewerCLI compact={compact} />;
  if (standing === 'loading') return compact ? null : <WaitlistCardSkeleton />;
  if (standing === 'login' || standing === 'unavailable')
    return (
      <WaitlistProblem
        backend={backend}
        kind={standing}
        error={waitlist.error}
        retry={waitlist.refresh}
        compact={compact}
        label="Waitlist"
      />
    );
  if (!entry || (compact && entry.status === 'approved')) return null;
  const props = { entry, waitlist, backend, standingRef };
  return compact ? <CompactCard {...props} /> : <FullCard {...props} onOpen={onOpen} />;
}

// After Join the button is gone; focus moves to where the account now stands, so keyboard and
// screen reader users land on the answer instead of the top of the page.
function useStandingFocus(status?: WaitlistEntry['status']) {
  const target = useRef<HTMLElement | null>(null);
  const previous = useRef(status);
  useEffect(() => {
    const was = previous.current;
    previous.current = status;
    if (was !== 'none' || !status || status === 'none') return;
    const active = document.activeElement;
    if (!active || active === document.body) target.current?.focus({ preventScroll: true });
  }, [status]);
  return useCallback((element: HTMLElement | null) => {
    target.current = element;
  }, []);
}

interface CardProps {
  entry: WaitlistEntry;
  waitlist: Waitlist;
  backend: BackendState;
  standingRef: (element: HTMLElement | null) => void;
}

function FullCard({
  entry,
  waitlist,
  backend,
  standingRef,
  onOpen,
}: CardProps & { onOpen?: () => void }) {
  const titleID = useId();
  const Icon = featureIcons[entry.feature] ?? Ticket;
  const StatusIcon = statusIcons[entry.status];
  const command = startCommand(entry);
  const summary = entry.summary?.trim();
  const detail =
    entry.status === 'waitlisted'
      ? reviewOrder
      : entry.status === 'revoked'
        ? revokedForGood
        : undefined;
  return (
    <article
      className={styles.card}
      data-status={entry.status}
      aria-labelledby={titleID}
      aria-busy={waitlist.joining || undefined}
    >
      <div className={styles.head}>
        <span className={styles.icon} data-tone={tone(entry.status)}>
          <Icon size={17} />
        </span>
        <div className={styles.copy}>
          <h2 id={titleID}>{printable(entry.title)}</h2>
          {summary && <p>{printable(summary)}</p>}
        </div>
        <div className={styles.side}>
          {entry.status === 'waitlisted' && entry.position != null && (
            <p className={styles.place}>
              <strong>#{entry.position}</strong> <span>in line</span>
            </p>
          )}
          {entry.status === 'none' && (
            <JoinButton waitlist={waitlist} backend={backend} describedBy={titleID} />
          )}
          {entry.status === 'approved' && onOpen && (
            <Button variant="primary" aria-describedby={titleID} onClick={onOpen}>
              Open <ArrowRight size={15} />
            </Button>
          )}
        </div>
      </div>
      <div className={styles.foot}>
        <p className={styles.standing} ref={standingRef} tabIndex={-1}>
          <StatusIcon size={14} />
          <span>
            {standingLine(entry, { place: false })}
            {detail && <small>{detail}</small>}
          </span>
        </p>
        {entry.status === 'approved' && !onOpen && command && <Command text={command} />}
        {waitlist.problem && (
          <p className={styles.problem} role="alert">
            {printableLines(waitlist.problem)}
          </p>
        )}
      </div>
    </article>
  );
}

function CompactCard({ entry, waitlist, backend, standingRef }: CardProps) {
  const Icon = featureIcons[entry.feature] ?? Ticket;
  const sentence = standingSentence(entry);
  return (
    <section
      className={styles.compact}
      data-status={entry.status}
      aria-label={`${printable(entry.title)} waitlist`}
      aria-busy={waitlist.joining || undefined}
    >
      <span className={styles.icon} data-tone={tone(entry.status)}>
        <Icon size={17} />
      </span>
      <div className={styles.copy}>
        <strong ref={standingRef} tabIndex={-1}>
          {sentence.line}
        </strong>
        {sentence.detail && <small>{sentence.detail}</small>}
      </div>
      {entry.status === 'none' && <JoinButton waitlist={waitlist} backend={backend} />}
      {waitlist.problem && (
        <p className={styles.problem} role="alert">
          {printableLines(waitlist.problem)}
        </p>
      )}
    </section>
  );
}

// The runtime runs one operation at a time, so Join waits while another one runs. On a page of
// cards, `describedBy` names the waitlist the button joins.
function JoinButton({
  waitlist,
  backend,
  describedBy,
}: {
  waitlist: Waitlist;
  backend: BackendState;
  describedBy?: string;
}) {
  return (
    <Button
      variant="primary"
      aria-describedby={describedBy}
      disabled={backend.busy || waitlist.joining}
      onClick={() => void waitlist.join()}
    >
      {waitlist.joining ? <LoaderCircle className="spin" size={15} /> : <Ticket size={15} />}
      {waitlist.joining ? 'Joining…' : 'Join the waitlist'}
    </Button>
  );
}

// A waitlist's start command, to run in Terminal; copying avoids mistyping it.
function Command({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <span className={styles.command}>
      <code title={text}>{text}</code>
      <button
        type="button"
        className="icon-button"
        aria-label={copied ? `Copied ${text}` : `Copy ${text}`}
        onClick={async () => {
          try {
            await api?.copy(text);
            setCopied(true);
          } catch {
            setCopied(false);
          }
        }}
      >
        {copied ? <Check size={14} /> : <Copy size={14} />}
      </button>
    </span>
  );
}

// The shape of a card while the list loads.
export function WaitlistCardSkeleton() {
  return (
    <div className={`${styles.card} ${styles.skeleton}`} aria-hidden="true">
      <div className={styles.head}>
        <span className={styles.icon} />
        <div className={styles.copy}>
          <i className={`${styles.bar} ${styles.short}`} />
          <i className={`${styles.bar} ${styles.long}`} />
        </div>
      </div>
      <div className={styles.foot}>
        <i className={`${styles.bar} ${styles.short}`} />
      </div>
    </div>
  );
}
