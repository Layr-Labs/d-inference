import type { BackendState } from '../../useBackend';
import { failedChecks, type Verdict } from './eligibility';
import { ScanCard } from './ScanCard';
import { ScanFooter } from './ScanFooter';
import type { MacScan } from './useMacScan';

const copy: Record<Verdict | 'checking', { title: string; lead: string }> = {
  checking: {
    title: 'Checking this Mac…',
    lead: 'Darkbloom makes sure this Mac can serve models before you set it up.',
  },
  eligible: {
    title: 'This Mac is eligible.',
    lead: 'It meets everything Darkbloom needs to serve models.',
  },
  ineligible: {
    title: 'This Mac isn’t eligible yet.',
    lead: 'It doesn’t meet everything Darkbloom needs to serve models today.',
  },
  unknown: {
    title: 'We couldn’t confirm everything.',
    lead: 'Some requirements couldn’t be checked. Check again, or continue: Darkbloom verifies that each model fits before loading it.',
  },
};

const count = (n: number, phrase: string) => `${n} requirement${n === 1 ? '' : 's'} ${phrase}`;

function caption({ result, settled }: MacScan, backend: BackendState) {
  if (!result) return backend.status.message || 'Reading this Mac…';
  if (!settled) return 'Checking requirements…';
  if (result.verdict === 'eligible') return 'Ready for Darkbloom';
  if (result.verdict === 'ineligible') return count(failedChecks(result.checks).length, 'not met');
  return count(result.checks.filter((check) => check.ok === null).length, 'couldn’t be checked');
}

export function ScanStep({
  backend,
  scan,
  next,
  proceed,
  explore,
}: {
  backend: BackendState;
  scan: MacScan;
  // What an eligible Mac moves on to: linking the account, or starting on a linked Mac.
  next: string;
  proceed: () => void;
  explore: () => void;
}) {
  const { result, frame, settled } = scan;
  const verdict = settled ? result?.verdict : undefined;
  const { title, lead } = copy[verdict ?? 'checking'];
  return (
    <>
      <h2 aria-live="polite">{title}</h2>
      <p>{lead}</p>
      <ScanCard
        name={backend.state?.machine.name}
        checks={result?.checks}
        frame={frame}
        verdict={verdict}
        caption={caption(scan, backend)}
      />
      <ScanFooter
        waitlist={!backend.state?.capabilities || backend.state.capabilities.includes('waitlist')}
        scan={scan}
        next={next}
        proceed={proceed}
        explore={explore}
      />
    </>
  );
}
