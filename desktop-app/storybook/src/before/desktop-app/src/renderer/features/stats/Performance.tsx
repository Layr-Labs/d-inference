import { useState } from 'react';
import type { BackendState } from '../../useBackend';
import { isPreview } from '../../useBackend';
import { count } from '../../format';
import { contribution } from '../home/contribution';
import { useRequestHistory } from './activity/useRequestHistory';
import { ModelWork } from './ModelWork';
import { PreviewPerformance } from './PreviewPerformance';
import { observedTraffic, recordedTraffic } from './data';
import { TrafficChart, type TrafficMetric } from './TrafficChart';
import styles from './stats.module.css';

export function Performance({ backend }: { backend: BackendState }) {
  return isPreview ? (
    <PreviewPerformance backend={backend} />
  ) : (
    <MacPerformance backend={backend} />
  );
}
export function MacPerformance({ backend }: { backend: BackendState }) {
  const state = backend.state!;
  const { history } = useRequestHistory(
    `${state.installation_id}:${state.account_revision ?? 'legacy'}`,
  );
  const usage = contribution(state.activity);
  const [metric, setMetric] = useState<TrafficMetric>('requests');
  const settled = history && history.records.length > 0;
  const points = settled ? recordedTraffic(history.records) : observedTraffic(state);
  return (
    <>
      <div className={styles.metrics}>
        <div>
          <span>Requests served</span>
          <strong>{count(state.activity.requests)}</strong>
          <small>This session</small>
        </div>
        <div>
          <span>Input tokens</span>
          <strong>{usage.input}</strong>
          <small>This session · confirmed</small>
        </div>
        <div>
          <span>Output tokens</span>
          <strong>{usage.output}</strong>
          <small>This session · confirmed</small>
        </div>
        <div>
          <span>Earned</span>
          <strong>{usage.earnings}</strong>
          <small>This session · settled</small>
        </div>
      </div>
      <div className={styles.metrics}>
        <div>
          <span>Tokens processed this session</span>
          <strong>{usage.tokens}</strong>
        </div>
        {state.activity.cached_input_tokens != null && (
          <div>
            <span>Cached input</span>
            <strong>{usage.cached}</strong>
          </div>
        )}
        {state.activity.reasoning_tokens != null && (
          <div>
            <span>Reasoning</span>
            <strong>{usage.reasoning}</strong>
          </div>
        )}
      </div>
      {points.length > 0 && (
        <TrafficChart
          points={points}
          metric={metric}
          onMetric={setMetric}
          scope={
            settled ? 'Settled requests · 30-minute intervals' : 'Observed intervals · this session'
          }
        />
      )}
      {history && <ModelWork records={history.records} models={state.models} />}
    </>
  );
}
