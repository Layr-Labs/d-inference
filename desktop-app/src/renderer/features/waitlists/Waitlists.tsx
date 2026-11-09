import type { ReactNode } from 'react';
import type { Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Header, Notice } from '../../components/UI';
import { WaitlistCard, WaitlistCardSkeleton } from './WaitlistCard';
import { NeedsNewerCLI, WaitlistProblem } from './WaitlistProblem';
import { useWaitlists } from './useWaitlist';
import { featurePages, printableLines } from './words';
import styles from './waitlists.module.css';

// Early access: every waitlist the coordinator offers, in its order, and where the account
// stands (`darkbloom waitlist`). A feature with a page here opens it once approved.
export function Waitlists({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const list = useWaitlists(backend);
  const entries = list.data?.data ?? [];
  let body: ReactNode;
  if (list.loading)
    body = (
      <ul className={styles.list} aria-label="Loading waitlists" aria-busy="true">
        {[0, 1].map((index) => (
          <li key={index}>
            <WaitlistCardSkeleton />
          </li>
        ))}
      </ul>
    );
  else if (!list.supported) body = <NeedsNewerCLI onUpdates={() => navigate('updates')} />;
  else if (entries.length)
    body = (
      <>
        {/* A failed refresh keeps the last answer on screen. */}
        {list.error && <Notice>{printableLines(list.error)}</Notice>}
        <ul className={styles.list} aria-label="Waitlists">
          {entries.map((entry) => {
            const page = featurePages[entry.feature];
            return (
              <li key={entry.feature}>
                <WaitlistCard
                  feature={entry.feature}
                  backend={backend}
                  onOpen={page ? () => navigate(page) : undefined}
                />
              </li>
            );
          })}
        </ul>
      </>
    );
  else
    body = (
      <WaitlistProblem
        backend={backend}
        kind={
          list.data?.code === 'login'
            ? 'login'
            : list.data?.code === 'none' || (list.data && !list.data.error)
              ? 'none'
              : 'unavailable'
        }
        error={list.data?.error ?? list.error}
        retry={list.refresh}
        onSettings={() => navigate('settings')}
      />
    );
  return (
    <>
      <Header title="Early access" description="Features Darkbloom opens to approved accounts." />
      {body}
    </>
  );
}
