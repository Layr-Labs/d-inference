import { Pause, Play, RefreshCw, Sparkles } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { phaseCopy } from './pool';
import styles from './autopilot.module.css';

export function AutopilotCard({
  snapshot,
  working,
  busy,
  onPause,
  onResume,
  onTurnOff,
  onRefresh,
}: {
  snapshot: Snapshot;
  working?: string;
  busy?: boolean;
  onPause: () => void;
  onResume: () => void;
  onTurnOff: () => void;
  onRefresh: () => void;
}) {
  const status = snapshot.autopilot!;
  const phase = phaseCopy(status, snapshot.state === 'running');
  const loaded = snapshot.models.filter((model) => model.loaded).length;
  return (
    <section className={styles.card} aria-label="Autopilot">
      <header>
        <span className={styles.icon}>
          <Sparkles size={18} />
        </span>
        <h3>Autopilot</h3>
        <span className={styles.phase} data-tone={phase.tone}>
          <i />
          {phase.label}
        </span>
        <span className={styles.counts}>
          {status.selected.length} available · {loaded} in memory
        </span>
        <div className={styles.controls}>
          {working ? (
            <span>{working}</span>
          ) : (
            <>
              <Button disabled={busy} onClick={status.paused ? onResume : onPause}>
                {status.paused ? <Play size={14} /> : <Pause size={14} />}
                {status.paused ? 'Resume' : 'Pause'}
              </Button>
              <Button disabled={busy} variant="quiet" onClick={onTurnOff}>
                Switch to manual
              </Button>
            </>
          )}
        </div>
      </header>
      {phase.detail && (
        <details className={styles.phaseDetails}>
          <summary>{phase.label} details</summary>
          <p>{phase.detail}</p>
          {phase.refresh && !working && (
            <Button disabled={busy} onClick={onRefresh}>
              <RefreshCw size={14} /> Update available models
            </Button>
          )}
        </details>
      )}
    </section>
  );
}
