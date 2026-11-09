import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { useWaitlist } from './useWaitlist';

// One feature's waitlist: where the account stands and, when not on it, Join.
export function WaitlistCard({ feature, backend }: { feature: string; backend: BackendState }) {
  const waitlist = useWaitlist(backend, feature);
  const entry = waitlist.entry;
  if (!entry) return null;
  return (
    <section className="settings-section">
      <h2>{entry.title}</h2>
      {entry.summary && <p>{entry.summary}</p>}
      <p>
        {entry.status === 'approved'
          ? 'Approved.'
          : entry.status === 'waitlisted'
            ? `#${entry.position ?? '?'} in line.`
            : entry.status === 'revoked'
              ? 'Not approved.'
              : 'Not joined.'}
      </p>
      {entry.status === 'none' && (
        <Button variant="primary" disabled={waitlist.joining} onClick={() => void waitlist.join()}>
          Join the waitlist
        </Button>
      )}
    </section>
  );
}
