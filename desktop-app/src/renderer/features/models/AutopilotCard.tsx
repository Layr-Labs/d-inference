import { Pause, Play, Power, RefreshCw, Sparkles } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { gb } from '../../format';
import { modelName, pinnedMemoryLine } from '../../models/facts';
import { phaseCopy } from './pool';
import styles from './autopilot.module.css';

const names = (snapshot: Snapshot, ids: string[]) =>
  ids.map((id) => modelName(snapshot.models, id));

function Fact({ label, values, empty }: { label: string; values: string[]; empty: string }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{values.length ? values.join(', ') : <span className="muted">{empty}</span>}</dd>
    </div>
  );
}

export function AutopilotCard({
  snapshot,
  working,
  onPause,
  onResume,
  onTurnOff,
  onRefresh,
}: {
  snapshot: Snapshot;
  working?: string;
  onPause: () => void;
  onResume: () => void;
  onTurnOff: () => void;
  onRefresh: () => void;
}) {
  const status = snapshot.autopilot!;
  const phase = phaseCopy(status, snapshot.state === 'running');
  const loaded = snapshot.models.filter((model) => model.loaded).map((model) => model.id);
  const { memory } = snapshot;
  const pins = pinnedMemoryLine(snapshot, status.pinned, 'pinned');
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
        <div className={styles.controls}>
          {working ? (
            <span className="muted">{working}</span>
          ) : (
            <>
              {status.paused ? (
                <Button onClick={onResume}>
                  <Play size={14} /> Resume
                </Button>
              ) : (
                <Button onClick={onPause}>
                  <Pause size={14} /> Pause
                </Button>
              )}
              <Button variant="quiet" onClick={onTurnOff}>
                <Power size={14} /> Turn off
              </Button>
            </>
          )}
        </div>
      </header>
      <p>
        You choose which models live on this Mac. Autopilot decides which ones to load into memory
        as demand changes.
      </p>
      {phase.detail && (
        <div className={styles.detail} data-tone={phase.tone}>
          <span>{phase.detail}</span>
          {phase.refresh && !working && (
            <Button onClick={onRefresh}>
              <RefreshCw size={14} /> Refresh pool
            </Button>
          )}
        </div>
      )}
      <dl className={styles.facts}>
        <Fact label="Loaded now" values={names(snapshot, loaded)} empty="Nothing loaded" />
        <Fact label="Pinned · always on" values={names(snapshot, status.pinned)} empty="No pins" />
        <div>
          <dt>Free to load</dt>
          <dd>
            {gb(memory.free_for_load_gb)}
            <span className="muted"> of {gb(memory.total_gb)}</span>
          </dd>
          <div className="memory-track">
            <span
              style={{
                width: `${Math.min(100, ((memory.active_gb || 0) / (memory.total_gb || 1)) * 100)}%`,
              }}
            />
          </div>
          {status.pinned.length > 0 && (
            <small className={pins.exceeds ? 'warning-text' : 'muted'}>{pins.text}</small>
          )}
        </div>
      </dl>
    </section>
  );
}
