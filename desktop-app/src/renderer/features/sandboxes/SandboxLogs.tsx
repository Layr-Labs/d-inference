import { useEffect, useRef, useState } from 'react';
import { RefreshCw } from 'lucide-react';
import type { SandboxLogs as Logs } from '../../../shared/sandbox';
import { Button } from '../../components/UI';
import { useResource } from '../../data/useResource';
import { timeOfDay } from '../../format';
import styles from './sandboxes.module.css';

// The add-on's log (`darkbloom sandbox logs`), read only while shown and on Refresh.
export function SandboxLogs({ id }: { id: string }) {
  const logs = useResource<Logs>('sandbox-logs');
  const [refreshing, setRefreshing] = useState(false);
  const view = useRef<HTMLPreElement>(null);
  const lines = logs.data?.lines ?? [];
  const error = logs.data?.error || logs.error;
  // Newest last, as `tail` prints it: open at the end.
  useEffect(() => {
    if (view.current) view.current.scrollTop = view.current.scrollHeight;
  }, [logs.data]);
  return (
    <section id={id} className={styles.logs} aria-label="Add-on log">
      <header>
        <h3>Add-on log</h3>
        {logs.data?.observed_at ? <span>Read at {timeOfDay(logs.data.observed_at)}</span> : null}
        <Button
          disabled={refreshing || logs.loading}
          onClick={async () => {
            setRefreshing(true);
            try {
              await logs.refresh();
            } finally {
              setRefreshing(false);
            }
          }}
        >
          <RefreshCw size={14} className={refreshing ? 'spin' : undefined} /> Refresh
        </Button>
      </header>
      {error && (
        <p className={styles.error} role="alert">
          {error}
        </p>
      )}
      {logs.loading && !logs.data ? (
        <p className={styles.logsEmpty} role="status">
          Reading the log…
        </p>
      ) : lines.length ? (
        <pre ref={view} tabIndex={0} aria-label="Log lines">
          {lines.join('\n')}
        </pre>
      ) : (
        !error && <p className={styles.logsEmpty}>The log is empty.</p>
      )}
    </section>
  );
}
