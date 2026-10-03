import { useId, useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { Button, Header } from '../components/UI';
import { TabPanel, Tabs } from '../components/Tabs';
import { Performance } from './stats/Performance';
import { RequestActivity } from './stats/activity/RequestActivity';
import styles from './stats/stats.module.css';

const views = [
  { id: 'performance', label: 'Performance' },
  { id: 'activity', label: 'Activity' },
] as const;

export function Stats({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const [view, setView] = useState<(typeof views)[number]['id']>('performance');
  const base = useId();
  return (
    <div className={styles.stats}>
      <Header
        level={embedded ? 2 : 1}
        title="Stats"
        description="See the work your Mac is doing."
        action={
          <Button disabled={backend.busy} onClick={() => void backend.act({ action: 'diagnose' })}>
            <ShieldCheck size={15} />
            Run diagnostics
          </Button>
        }
      />
      <Tabs base={base} label="Stats views" tabs={views} selected={view} onSelect={setView} />
      <TabPanel base={base} tab={view} className={styles.view}>
        {view === 'performance' ? (
          <Performance backend={backend} />
        ) : (
          <RequestActivity models={backend.state!.models} />
        )}
      </TabPanel>
    </div>
  );
}
