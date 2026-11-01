import { useEffect, useRef, useState } from 'react';
import { Check, Flag, Sparkles } from 'lucide-react';
import { tokenProgress } from './activity';
import { compact } from '../../format';
import styles from './insights.module.css';

export function TokenMilestones({ tokens }: { tokens: bigint }) {
  const { achieved, next, previous, progress } = tokenProgress(tokens);
  const lastMilestone = useRef(previous);
  const [celebration, setCelebration] = useState<bigint | null>(null);
  useEffect(() => {
    if (previous > lastMilestone.current) {
      lastMilestone.current = previous;
      setCelebration(previous);
    }
  }, [previous]);
  useEffect(() => {
    if (celebration === null) return;
    const timeout = setTimeout(() => setCelebration(null), 10_000);
    return () => clearTimeout(timeout);
  }, [celebration]);
  const visible = [...achieved.slice(-2), ...(next === null ? [] : [next])];
  const progressDescription =
    next === null ? 'all milestones reached' : `next milestone ${next.toLocaleString()}`;
  return (
    <section className={styles.milestones} aria-labelledby="token-milestones-title">
      <div className={styles.sectionHead}>
        <h2 id="token-milestones-title">Every token adds up</h2>
        <Flag size={19} className="text-accent-brand" />
      </div>
      <p className={styles.tokenTotal} title={tokens.toLocaleString()}>
        {compact(tokens)} <span>output tokens served</span>
      </p>
      <div className={styles.progressLabels}>
        <span>
          {next === null
            ? 'All milestones reached'
            : `${compact(next - tokens)} to your next milestone`}
        </span>
        <strong>{next === null ? compact(previous) : compact(next)}</strong>
      </div>
      <div
        role="progressbar"
        aria-label="Progress to next token milestone"
        aria-valuenow={Math.round(progress)}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuetext={`${tokens.toLocaleString()} output tokens; ${progressDescription}`}
        className={styles.progress}
      >
        <span style={{ width: `${progress}%` }} />
      </div>
      <div className={styles.milestoneList}>
        {visible.map((target) => (
          <span key={target} data-reached={tokens >= target}>
            {tokens >= target ? <Check size={14} /> : <Flag size={14} />}
            <strong>{compact(target)}</strong>
            <small>{tokens >= target ? 'Reached' : 'Up next'}</small>
          </span>
        ))}
      </div>
      <div role="status">
        {celebration !== null && (
          <p className={styles.celebration}>
            <Sparkles size={17} />
            {compact(celebration)} output tokens. Milestone reached!
          </p>
        )}
      </div>
      <p className={styles.note}>
        Lifetime output tokens from settled inference earnings, including removed Macs. Prompt
        tokens and base rewards do not count.
      </p>
    </section>
  );
}
