import type { Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Header } from '../../components/UI';
import { WaitlistCard } from './WaitlistCard';
import { useWaitlists } from './useWaitlist';

// Every waitlist the coordinator offers and where the account stands.
export function Waitlists({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  void navigate;
  const waitlists = useWaitlists(backend);
  return (
    <>
      <Header title="Early access" description="Features Darkbloom opens to approved accounts." />
      {waitlists.data?.data.map((entry) => (
        <WaitlistCard key={entry.feature} feature={entry.feature} backend={backend} />
      ))}
    </>
  );
}
