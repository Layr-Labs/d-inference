import type { Route } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Header } from '../../components/UI';

// Chat with the models this Mac serves on its local API.
export function Chat({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  void backend;
  void navigate;
  return <Header title="Chat" description="Talk to the models on this Mac." />;
}
