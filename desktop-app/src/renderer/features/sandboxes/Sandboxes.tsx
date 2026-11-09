import type { Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Header } from '../../components/UI';

// Darkbloom Sandbox: CI jobs in Linux and macOS VMs on this Mac.
export function Sandboxes({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  void backend;
  void navigate;
  return <Header title="Sandboxes" description="Run Darkbloom Sandbox CI jobs on this Mac." />;
}
