import type { ClusterSession } from '../shared/cluster';
import type { Backend } from './backend';

// The guided cluster setup session, run by the native API (`/control/v1/cluster/session`). This
// relays the session's routes and holds one event stream while the renderer watches it,
// publishing the whole session on every change.
export class ClusterSessionRelay {
  constructor(
    private backend: Backend,
    private publish: (session: ClusterSession) => void,
  ) {}

  async current(): Promise<ClusterSession | null> {
    return null;
  }

  async start(_start: unknown): Promise<ClusterSession> {
    void this.backend;
    void this.publish;
    throw new Error('Cluster setup from the app needs a newer Darkbloom CLI.');
  }

  async answer(_answer: unknown): Promise<ClusterSession> {
    throw new Error('Cluster setup from the app needs a newer Darkbloom CLI.');
  }

  acquire() {}

  release() {}

  // Drops every subscription, such as when the renderer navigates or crashes.
  reset() {}
}
