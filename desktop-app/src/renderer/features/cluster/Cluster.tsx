import { ArrowUpRight, LoaderCircle, RotateCw } from 'lucide-react';
import { useState } from 'react';
import type { Route } from '../../../shared/contracts';
import type { ClusterStatus } from '../../../shared/cluster';
import type { BackendState } from '../../useBackend';
import { Button, Header, Notice } from '../../components/UI';
import { useResource } from '../../data/useResource';
import { NotPaired } from './NotPaired';
import { PairStatus } from './PairStatus';
import { knownState } from './status';
import { useClusterSession } from './useClusterSession';
import { Wizard } from './Wizard';
import styles from './cluster.module.css';

// Two Macs serving one model together: setting up a pair, its model and how it serves, and
// running it. The pair's state is `darkbloom cluster status`'s; its setup is `darkbloom
// cluster`'s own screen, shown with the app's controls while it runs.
export function Cluster({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  const capabilities = state.capabilities ?? [];
  const supported = capabilities.includes('cluster');
  const guided = supported && capabilities.includes('cluster_session');
  const status = useResource<ClusterStatus>('cluster', {
    enabled: supported,
    refreshKey: state.resource_revision,
  });
  const session = useClusterSession(guided, () => void status.refresh());
  const [refreshing, setRefreshing] = useState(false);
  const refresh = async () => {
    setRefreshing(true);
    try {
      await status.refresh();
    } finally {
      setRefreshing(false);
    }
  };

  if (!supported)
    return (
      <div className={styles.page}>
        <Header title="Clusters" />
        <p className={styles.unsupported}>
          Clusters need a newer Darkbloom CLI.{' '}
          <button type="button" className="text-link" onClick={() => navigate('updates')}>
            Updates <ArrowUpRight size={13} aria-hidden="true" />
          </button>
        </p>
      </div>
    );

  if (session.shown)
    return (
      <div className={styles.page}>
        <Wizard
          session={session.shown}
          control={session}
          onRestart={() => void session.start(session.shown!.kind)}
        />
      </div>
    );

  // A state a newer runtime added reads as unknown, with its own reason and next step.
  const data: ClusterStatus | undefined =
    status.data && !status.data.error
      ? { ...status.data, state: knownState(status.data.state) ? status.data.state : 'unknown' }
      : undefined;
  const failure = status.data?.error ?? (status.data ? undefined : status.error);
  // Until the status answers (up to 10 s on the Mac that follows), the snapshot says whether
  // this Mac is paired.
  const paired = data ? data.state !== 'not_paired' : !!state.pair;
  const control = guided ? session : null;
  const busy = refreshing || status.loading;
  return (
    <div className={styles.page}>
      <Header
        title="Clusters"
        action={
          <Button disabled={busy} onClick={() => void refresh()} aria-busy={busy || undefined}>
            <RotateCw size={14} className={busy ? 'spin' : undefined} aria-hidden="true" />
            Refresh
          </Button>
        }
      />
      {failure && (
        <Notice>
          <span>
            Couldn’t read the pair. <span className={styles.failure}>{failure}</span>
          </span>
        </Notice>
      )}
      {!paired ? (
        <NotPaired backend={backend} session={control} />
      ) : data ? (
        <PairStatus
          backend={backend}
          status={data}
          refreshing={busy}
          refresh={refresh}
          session={control}
        />
      ) : (
        <section className={styles.pair} aria-label="Pair" aria-busy={status.loading || undefined}>
          <div className={styles.reading} role="status">
            {status.loading && <LoaderCircle className="spin" size={15} aria-hidden="true" />}
            {state.pair?.model && <strong>{state.pair.model}</strong>}
            <span>
              {status.loading ? 'Reading the pair…' : 'The pair’s status is unavailable.'}
            </span>
          </div>
        </section>
      )}
    </div>
  );
}
