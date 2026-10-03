import { ArrowRight, RotateCw } from 'lucide-react';
import type { CSSProperties } from 'react';
import { Button } from '../UI';
import { failedChecks } from './eligibility';
import { scanTiming } from './scanScript';
import type { MacScan } from './useMacScan';
import { WaitlistForm } from './WaitlistForm';
import styles from './scanFooter.module.css';

export function ScanFooter({
  scan,
  proceed,
  explore,
}: {
  scan: MacScan;
  proceed: () => void;
  explore: () => void;
}) {
  const { result, settled } = scan;
  if (!result) return null;
  if (!settled)
    return (
      <div className={styles.advance}>
        <button className="text-link" onClick={scan.finish}>
          Skip <ArrowRight size={13} />
        </button>
      </div>
    );
  if (result.verdict === 'eligible')
    return (
      <div className={styles.advance}>
        <span
          className={styles.countdown}
          style={{ '--countdown': `${scanTiming.holdMs + scanTiming.exitMs}ms` } as CSSProperties}
        />
        <span>Next: start serving</span>
        <button className="text-link" onClick={scan.finish}>
          Continue now <ArrowRight size={13} />
        </button>
      </div>
    );
  const links = (
    <div className={styles.links}>
      <button className="text-link" onClick={() => void scan.recheck()}>
        <RotateCw size={13} /> Check again
      </button>
      <button className="text-link" onClick={explore}>
        Open dashboard <ArrowRight size={13} />
      </button>
    </div>
  );
  return result.verdict === 'ineligible' ? (
    <>
      <WaitlistForm reasons={failedChecks(result.checks).map((check) => check.id)} />
      {links}
    </>
  ) : (
    <>
      <Button variant="primary" onClick={proceed}>
        Continue setup <ArrowRight size={16} />
      </Button>
      {links}
    </>
  );
}
