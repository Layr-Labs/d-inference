import { useState } from 'react';
import { ChevronDown } from 'lucide-react';
import type { BackendState } from '../useBackend';
import type { Leader } from '../../shared/contracts';
import { compact, money } from '../format';
import { Button, Empty, Header } from '../components/UI';
import { NetworkMap } from './leaderboard/NetworkMap';
import { ProviderMark } from './leaderboard/ProviderMark';
import { annualPace } from './leaderboard/data';
import styles from './leaderboard/leaderboard.module.css';

function Provider({ leader, featured }: { leader: Leader; featured?: boolean }) {
  return (
    <details className={featured ? styles.featured : styles.provider}>
      <summary aria-label={`Rank ${leader.rank}, ${leader.name}`}>
        <span className={styles.rank}>{leader.rank.toString().padStart(2, '0')}</span>
        <ProviderMark name={leader.name} />
        <strong className={styles.name}>{leader.name}</strong>
        <span className={styles.pace}>
          {annualPace(leader.earnings_micro_usd)}
          <small>/yr</small>
        </span>
        <ChevronDown size={14} className={styles.chevron} />
      </summary>
      <dl className={styles.details}>
        <div>
          <dt>Earned in 24 hours</dt>
          <dd>{money(leader.earnings_micro_usd)}</dd>
        </div>
        <div>
          <dt>Input + output tokens</dt>
          <dd>{compact(leader.tokens)}</dd>
        </div>
      </dl>
    </details>
  );
}

export function Leaderboard({ backend }: { backend: BackendState }) {
  const [visible, setVisible] = useState(10);
  const leaders = backend.leaders ?? [];
  const loading = backend.leaders === undefined && !backend.leaderError;
  return (
    <div className={styles.page}>
      <Header title="Leaderboard" description="The people powering Darkbloom." />
      <NetworkMap network={backend.network} />
      <div className={styles.heading}>
        <h2>Top providers</h2>
        <span>Annualized earnings · past 24 hours</span>
      </div>
      {backend.leaderError && (
        <p role="status" className={styles.notice}>
          {backend.leaderError}
          {leaders.length ? ' Showing the last results.' : ''}
        </p>
      )}
      {leaders.length ? (
        <>
          <section className={styles.podium} aria-label="Top three providers">
            {leaders.slice(0, 3).map((leader) => (
              <Provider key={`${leader.rank}:${leader.name}`} leader={leader} featured />
            ))}
          </section>
          {leaders.length > 3 && (
            <section className={styles.rankings} aria-label="Provider rankings">
              <div className={styles.listHeading}>
                <span>Provider</span>
                <span>Annualized pace</span>
              </div>
              {leaders.slice(3, visible).map((leader) => (
                <Provider key={`${leader.rank}:${leader.name}`} leader={leader} />
              ))}
            </section>
          )}
          {visible < leaders.length && (
            <Button onClick={() => setVisible((count) => count + 10)}>Show more providers</Button>
          )}
          <p className={styles.note}>24-hour earnings × 365. A pace, not guaranteed income.</p>
        </>
      ) : loading ? (
        <p role="status" className={styles.notice}>
          Loading rankings…
        </p>
      ) : backend.leaderError ? (
        <Empty title="Leaderboard unavailable">
          Rankings will appear when the network responds.
        </Empty>
      ) : (
        <Empty title="No rankings yet">
          Providers appear here once they settle earnings in the past 24 hours.
        </Empty>
      )}
    </div>
  );
}
