import { ArrowRight, RefreshCw, RotateCw } from 'lucide-react';
import type { CSSProperties } from 'react';
import { openSoftwareUpdate } from '../../softwareUpdate';
import { Button } from '../UI';
import { failedChecks } from './eligibility';
import { scanTiming } from './scanScript';
import type { MacScan } from './useMacScan';
import { WaitlistForm } from './WaitlistForm';
import styles from './scanFooter.module.css';

export function ScanFooter({
  scan,
  next = 'start serving',
  proceed,
  explore,
  waitlist = true,
}: {
  scan: MacScan;
  next?: string;
  proceed: () => void;
  explore: () => void;
  waitlist?: boolean;
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
        <span>Next: {next}</span>
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
  const reasons = failedChecks(result.checks).map((check) => check.id);
  return result.verdict === 'ineligible' ? (
    <>
      {/* An older macOS is the one reason this Mac can fix itself. */}
      {reasons.includes('macos') && (
        <Button variant="primary" onClick={openSoftwareUpdate}>
          <RefreshCw size={16} /> Open Software Update
        </Button>
      )}
      {waitlist && <WaitlistForm reasons={reasons} />}
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
