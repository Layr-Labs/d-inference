import { Link2 } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { Button, Notice } from '../UI';
import { LinkPanel } from './LinkPanel';
import type { AccountLink } from './useAccountLink';

// Shown once the Darkbloom CLI is connected and this Mac passed the check (or from Start on an
// unlinked Mac); a linked Mac moves on by itself.
export function LinkStep({ backend, link }: { backend: BackendState; link: AccountLink }) {
  if (!backend.state) return null;
  return (
    <>
      <h2>Link your account.</h2>
      <p>Earnings from this Mac go to your Darkbloom account. Link it once, then start serving.</p>
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
