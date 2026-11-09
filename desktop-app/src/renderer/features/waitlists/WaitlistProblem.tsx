import { useState } from 'react';
import { ArrowRight, CircleAlert, Info, Link2, LoaderCircle, RotateCw, Ticket } from 'lucide-react';
import { Button, Notice } from '../../components/UI';
import { LinkPanel } from '../../components/onboarding/LinkPanel';
import { useAccountLink } from '../../components/onboarding/useAccountLink';
import type { BackendState } from '../../useBackend';
import { printableLines } from './words';
import styles from './waitlists.module.css';

export type WaitlistProblemKind = 'login' | 'none' | 'unavailable';

export const linkFirst = 'Link this Mac to your Darkbloom account first.';
const relink = 'Unlink this Mac in Settings, then link it again.';
const noWaitlists = 'There’s nothing to join here yet.';
const unavailable = 'Waitlists are unavailable right now.';

// Why the waitlists can't be shown, and the one thing to do about it: link this Mac (the app's
// own link flow), try again, or nothing when the coordinator has no waitlists. `error` is the
// runtime's sentence, shown as it is.
export function WaitlistProblem({
  backend,
  kind,
  error,
  retry,
  compact = false,
  onSettings,
}: {
  backend: BackendState;
  kind: WaitlistProblemKind;
  error?: string;
  retry: () => Promise<void>;
  compact?: boolean;
  // Opens This Mac's Settings, where a link the coordinator refuses is undone.
  onSettings?: () => void;
}) {
  const linked = !!backend.state?.linked;
  const message = error ? printableLines(error) : undefined;
  const line =
    kind === 'login'
      ? linked
        ? (message ?? 'Darkbloom didn’t accept this Mac’s link.')
        : linkFirst
      : kind === 'none'
        ? compact
          ? (message ?? noWaitlists)
          : 'No waitlists'
        : (message ?? unavailable);
  const detail =
    kind === 'login' && linked
      ? relink
      : kind === 'none' && !compact
        ? (message ?? noWaitlists)
        : undefined;
  const Icon = kind === 'login' ? Link2 : kind === 'none' ? Ticket : CircleAlert;
  return (
    <section
      className={compact ? styles.compact : styles.panel}
      aria-label={compact ? 'Waitlist' : 'Waitlists'}
    >
      <span className={styles.icon} data-tone={kind === 'unavailable' ? 'warning' : 'muted'}>
        <Icon size={17} />
      </span>
      <div className={styles.copy}>
        <strong className={styles.message}>{line}</strong>
        {detail && <small>{detail}</small>}
      </div>
      {kind === 'login' && !linked && <LinkAccount backend={backend} />}
      {kind === 'login' && linked && onSettings && (
        <Button onClick={onSettings}>
          Open Settings <ArrowRight size={15} />
        </Button>
      )}
      {kind === 'unavailable' && <TryAgain retry={retry} />}
    </section>
  );
}

// The app's link flow, as onboarding runs it: Link account starts the `link` action, the panel
// shows its code and Open link page, and the list reads again once the account is linked. A link
// already running (from Home or Models) shows its code here too.
function LinkAccount({ backend }: { backend: BackendState }) {
  const link = useAccountLink(backend);
  const state = backend.state!;
  if (link.linking || state.link) {
    const stop = () => {
      if (link.linking) return link.cancel();
      const running = state.operations.find(
        (operation) => operation.action === 'link' && operation.state === 'running',
      );
      if (running?.cancellable) void backend.act({ action: 'cancel', operation: running.id });
    };
    return (
      <div className={styles.linkFlow}>
        <LinkPanel link={state.link} cancel={stop} />
      </div>
    );
  }
  return (
    <>
      <Button variant="primary" disabled={backend.busy} onClick={() => void link.begin()}>
        <Link2 size={15} /> Link account
      </Button>
      {link.problem && (
        <div className={styles.linkFlow}>
          <Notice>{link.problem}</Notice>
        </div>
      )}
    </>
  );
}

function TryAgain({ retry }: { retry: () => Promise<void> }) {
  const [trying, setTrying] = useState(false);
  return (
    <Button
      disabled={trying}
      onClick={async () => {
        setTrying(true);
        try {
          await retry();
        } finally {
          setTrying(false);
        }
      }}
    >
      {trying ? <LoaderCircle className="spin" size={15} /> : <RotateCw size={15} />}
      {trying ? 'Trying…' : 'Try again'}
    </Button>
  );
}

// A runtime without the `waitlists` capability can't say where the account stands.
export function NeedsNewerCLI({
  compact = false,
  onUpdates,
}: {
  compact?: boolean;
  onUpdates?: () => void;
}) {
  return (
    <p className={compact ? `${styles.note} ${styles.noteCompact}` : styles.note}>
      <span>
        <Info size={14} /> Early access needs a newer Darkbloom CLI.
      </span>
      {onUpdates && (
        <button type="button" className="text-link" onClick={onUpdates}>
          Open Updates <ArrowRight size={14} />
        </button>
      )}
    </p>
  );
}
