import { ArrowRight, Cable, Download, LoaderCircle, Monitor } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { WaitlistCard } from '../waitlists/WaitlistCard';
import { useWaitlist } from '../waitlists/useWaitlist';
import { PairGlyph } from './PairGlyph';
import { CopyCommand } from './Rich';
import type { ClusterSessionControl } from './useClusterSession';
import styles from './cluster.module.css';

const needs = [
  { icon: Monitor, text: 'Two Apple silicon Macs' },
  { icon: Cable, text: 'A Thunderbolt cable' },
  { icon: Download, text: 'Darkbloom on both' },
];

// A Mac in no pair: what a pair needs, where the account stands on the cluster waitlist, and the
// two ways to start. Serving through Darkbloom needs the waitlist's approval (or a coordinator
// without that waitlist); serving on your own Macs only needs none.
export function NotPaired({
  backend,
  session,
}: {
  backend: BackendState;
  // Null when this runtime has no in-app setup: the steps are Terminal's.
  session: ClusterSessionControl | null;
}) {
  const waitlist = useWaitlist(backend, 'cluster');
  const starting = session?.pending === 'start';
  return (
    <>
      <section className={styles.hero} aria-labelledby="cluster-hero">
        <PairGlyph mood="invite" className={styles.heroGlyph} />
        <h2 id="cluster-hero">Two Macs. One model.</h2>
        <ul className={styles.needs} aria-label="What you need">
          {needs.map(({ icon: Icon, text }) => (
            <li key={text}>
              <Icon size={15} strokeWidth={1.6} aria-hidden="true" />
              {text}
            </li>
          ))}
        </ul>
        {session ? (
          <div className={styles.heroActions}>
            {(waitlist.open || waitlist.standing === 'loading') && (
              <Button
                variant="primary"
                disabled={!waitlist.open || !!session.pending || backend.busy}
                onClick={() => void session.start('setup')}
              >
                {starting ? <LoaderCircle className="spin" size={15} aria-hidden="true" /> : null}
                Set up a pair <ArrowRight size={15} aria-hidden="true" />
              </Button>
            )}
            <Button
              disabled={!!session.pending || backend.busy}
              onClick={() => void session.start('local')}
            >
              Serve on my own Macs only
            </Button>
          </div>
        ) : (
          <div className={styles.heroCommands}>
            <p>Run on each Mac in Terminal:</p>
            {waitlist.open && <CopyCommand command="darkbloom cluster" />}
            <CopyCommand
              command="darkbloom cluster local"
              label={waitlist.open ? 'Own Macs only' : undefined}
            />
          </div>
        )}
        {!waitlist.open && waitlist.standing !== 'loading' && (
          <p className={styles.heroNote}>
            {waitlist.standing === 'login' || waitlist.standing === 'unavailable'
              ? waitlist.error
              : 'Serving on your own Macs only needs no approval.'}
          </p>
        )}
        {session?.error && (
          <p className={styles.heroError} role="alert">
            {session.error}
          </p>
        )}
      </section>
      <WaitlistCard feature="cluster" backend={backend} />
    </>
  );
}
