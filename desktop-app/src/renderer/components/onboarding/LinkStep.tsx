import { Link2 } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { Button, Notice } from '../UI';
import { LinkPanel } from './LinkPanel';
import { RuntimeSetup } from './RuntimeSetup';
import type { AccountLink } from './useAccountLink';
import type { MacScan } from './useMacScan';

// Linking needs the runtime, so this step installs or waits for it first. A linked Mac moves on
// by itself.
export function LinkStep({
  backend,
  scan,
  link,
}: {
  backend: BackendState;
  scan: MacScan;
  link: AccountLink;
}) {
  if (scan.blocked) return <RuntimeSetup backend={backend} />;
  if (!backend.state)
    return (
      <>
        <h2 aria-live="polite">
          {backend.status.state === 'installing'
            ? 'Installing Darkbloom…'
            : 'Connecting to this Mac…'}
        </h2>
        <p>Setup continues as soon as Darkbloom’s verified native runtime is ready.</p>
        {backend.status.message && <p role="status">{backend.status.message}</p>}
      </>
    );
  return (
    <>
      <h2>Link your account.</h2>
      <p>
        Earnings from this Mac go to your Darkbloom account. Link it once, then Darkbloom checks
        that this Mac can serve models.
      </p>
      {link.problem && <Notice>{link.problem}</Notice>}
      {link.linking ? (
        <LinkPanel link={backend.state.link} cancel={link.cancel} />
      ) : (
        <Button variant="primary" disabled={backend.busy} onClick={() => void link.begin()}>
          <Link2 size={16} /> Link account
        </Button>
      )}
    </>
  );
}
