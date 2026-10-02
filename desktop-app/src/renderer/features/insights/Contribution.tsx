import type { Snapshot } from '../../../shared/contracts';
import { TokenMilestones } from './TokenMilestones';
import { useInsights } from './useInsights';
import { compact, earned, money, maximum, percent } from './types';
import styles from './insights.module.css';

export function Contribution({ state, onEarnings }: { state: Snapshot; onEarnings: () => void }) {
  const { data, error } = useInsights(state);
  if (!data)
    return (
      <p className={styles.note}>
        {!state.linked
          ? 'Link your account to track lifetime milestones and earnings.'
          : error || 'Loading your contribution history…'}
      </p>
    );
  const max = maximum(data.days.map(earned));
  return (
    <>
      <div className={styles.twoUp}>
        <TokenMilestones tokens={data.lifetime.completion_tokens} />
        <section className={styles.pulse}>
          <div className={styles.sectionHead}>
            <h2>7 calendar days</h2>
            <button className={styles.textButton} onClick={onEarnings}>
              Explore earnings
            </button>
          </div>
          <p className={styles.pulseTotal}>
            {money(earned(data.totals))}
            <span>settled earnings</span>
          </p>
          <div
            className={styles.sparkline}
            role="img"
            aria-label="Daily settled earnings over the last seven days"
          >
            {data.days.map((day) => (
              <span key={day.id} title={`${day.id}: ${money(earned(day))}`}>
                <i style={{ height: `${percent(earned(day), max)}%` }} />
              </span>
            ))}
          </div>
          <p className={styles.note}>
            {compact(data.totals.jobs)} requests · {compact(data.totals.completion_tokens)} output
            tokens
            <br />
            Includes {money(data.totals.base_reward_micro_usd)} base rewards. Today is partial.
          </p>
        </section>
      </div>
      {error && <p className={styles.notice}>{error} Showing the last observation.</p>}
    </>
  );
}
