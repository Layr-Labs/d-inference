import type {
  ClusterSession,
  ClusterSessionAnswer,
  ClusterSessionStart,
} from '../../shared/cluster';

// Development preview of the guided cluster setup: a scripted session. Never used for live data.
export const previewClusterSession = {
  async current(): Promise<ClusterSession | null> {
    return null;
  },
  async start(_start: ClusterSessionStart): Promise<ClusterSession> {
    throw new Error('Cluster setup preview is not built yet.');
  },
  async answer(_answer: ClusterSessionAnswer): Promise<ClusterSession> {
    throw new Error('Cluster setup preview is not built yet.');
  },
  watch(_callback: (session: ClusterSession) => void): () => void {
    return () => {};
  },
};
