import { Check, CircleHelp, Laptop, LoaderCircle, X } from 'lucide-react';
import type { ReactNode } from 'react';
import type { EligibilityCheck } from '../../../shared/eligibility';
import { CheckMark } from './CheckMark';
import type { Verdict } from './eligibility';
import type { ScanFrame } from './scanScript';
import styles from './scanCard.module.css';

type RowState = 'pending' | 'checking' | 'passed' | 'failed' | 'unknown';
const marks: Record<RowState, { label: string; icon?: ReactNode }> = {
  pending: { label: 'Waiting' },
  checking: { label: 'Checking', icon: <LoaderCircle className="spin" size={14} /> },
  passed: { label: 'Met', icon: <Check size={15} strokeWidth={2.2} /> },
  failed: { label: 'Not met', icon: <X size={15} strokeWidth={2.2} /> },
  unknown: { label: 'Couldn’t check', icon: <CircleHelp size={15} /> },
};

function rowState(check: EligibilityCheck, index: number, frame: ScanFrame): RowState {
  if (index >= frame.revealed) return 'pending';
  if (index >= frame.resolved) return 'checking';
  return check.ok ? 'passed' : check.ok === false ? 'failed' : 'unknown';
}

export function ScanCard({
  name,
  checks,
  frame,
  verdict,
  caption,
}: {
  name?: string;
  checks?: EligibilityCheck[];
  frame: ScanFrame;
  verdict?: Verdict;
  caption: string;
}) {
  return (
    <section
      className={styles.card}
      aria-label="This Mac"
      aria-busy={!verdict}
      data-phase={frame.phase}
      data-verdict={verdict}
    >
      <header className={styles.header}>
        <span className={styles.device}>
          <Laptop size={20} strokeWidth={1.6} />
        </span>
        <span className={styles.identity}>
          {name ? <strong>{name}</strong> : <i className={styles.placeholder} />}
          <small>{caption}</small>
        </span>
        {verdict === 'eligible' && <CheckMark />}
      </header>
      <ul className={styles.rows}>
        {checks
          ? checks.map((check, index) => (
              <ScanRow
                key={`${index}-${check.id}`}
                check={check}
                state={rowState(check, index, frame)}
              />
            ))
          : [0, 1, 2].map((index) => (
              <li className={styles.row} data-state="pending" key={index}>
                <i className={styles.placeholder} />
                <i className={styles.placeholder} />
                <span className={styles.mark} />
              </li>
            ))}
      </ul>
    </section>
  );
}

function ScanRow({ check, state }: { check: EligibilityCheck; state: RowState }) {
  const mark = marks[state];
  return (
    <li className={styles.row} data-state={state}>
      <span className={styles.label}>{check.label}</span>
      {state === 'pending' ? (
        <i className={styles.placeholder} />
      ) : (
        <span className={styles.value}>{check.value ?? '—'}</span>
      )}
      <span className={styles.mark} role="img" aria-label={mark.label}>
        {mark.icon}
      </span>
      {(state === 'failed' || state === 'unknown') && check.detail && (
        <p className={styles.detail}>{check.detail}</p>
      )}
    </li>
  );
}
