import type { Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Header } from '../../components/UI';

// Two Macs serving one model together: pairing, the pair's model and how it serves.
export function Cluster({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  void backend;
  void navigate;
  return <Header title="Clusters" description="Serve one model with two of your Macs." />;
}
