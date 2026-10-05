import { useState, type ReactNode } from 'react';
import type { ModelEarnings } from './earnings';
import { Check, SlidersHorizontal } from 'lucide-react';
import type { NativeModel } from '../../../shared/contracts';
import { Button, Empty, Header, Notice } from '../../components/UI';
import { pinnedMemory } from '../../models/selection';
import type { BackendState } from '../../useBackend';
import { AutopilotCard } from './AutopilotCard';
import { AutopilotConfirm, type AutopilotChange } from './AutopilotConfirm';
import { matchesQuery, ModelToolbar } from './ModelToolbar';
import { inFilter, poolFilters, poolState, runningDownload, type PoolFilter } from './pool';
import { PoolRow } from './PoolRow';
import { RemoveModelDialog } from './RemoveModelDialog';
import type { ModelActions } from './useModelActions';

// The pool: downloaded models Autopilot may load. People choose what lives on this Mac and what
// is pinned; Autopilot chooses what's in memory, so there is no selection to apply.
export function AutopilotModels({
  backend,
  actions,
  embedded,
  models,
  earnings,
  order,
}: {
  backend: BackendState;
  actions: ModelActions;
  embedded: boolean;
  models: NativeModel[];
  earnings: ModelEarnings;
  order: ReactNode;
}) {
  const state = backend.state!;
  const status = state.autopilot!;
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<PoolFilter>('all');
  const [remove, setRemove] = useState<NativeModel>();
  const [confirm, setConfirm] = useState<AutopilotChange>();
  const rows = models.map((model) => {
    const download = runningDownload(state, model.id, actions.downloads);
    return { model, download, state: poolState(model, status, !!download) };
  });
  const shown = rows.filter((row) => matchesQuery(row.model, query) && inFilter(row.state, filter));
  const pool = rows.filter((row) => inFilter(row.state, 'pool'));
  const startable = state.models
    .filter((model) => model.downloaded && (model.serving || status.selected.includes(model.id)))
    .map((model) => model.id);
  const pinBlocked = (model: NativeModel) =>
    pinnedMemory(state, [...status.pinned, model.id]).exceeds
      ? 'Pinning this needs more memory than this Mac has.'
      : undefined;
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Models"
        description="Choose which models live on this Mac. Autopilot loads them as demand changes."
        action={
          state.state !== 'running' && (
            <Button
              variant="primary"
              disabled={backend.busy || !startable.length}
              onClick={() => void backend.act({ action: 'start', models: startable })}
            >
              Start serving <Check size={16} />
            </Button>
          )
        }
      />
      {state.catalog_error && <Notice>{state.catalog_error}</Notice>}
      {actions.problem && <Notice onClose={actions.dismiss}>{actions.problem}</Notice>}
      <AutopilotCard
        snapshot={state}
        working={actions.working.autopilot}
        onPause={() => setConfirm('pause')}
        onResume={() => void actions.policy({ action: 'autopilot_resume' }, 'Resuming…')}
        onTurnOff={() => setConfirm('disable')}
        onRefresh={() => void actions.policy({ action: 'autopilot_models' }, 'Refreshing…')}
      />
      <ModelToolbar
        filters={poolFilters}
        filter={filter}
        onFilter={setFilter}
        query={query}
        onQuery={setQuery}
      />
      {order}
      {shown.length ? (
        <div className="model-list">
          {shown.map((row) => (
            <PoolRow
              key={row.model.id}
              model={row.model}
              earnings={earnings}
              state={row.state}
              download={row.download}
              working={actions.working[row.model.id]}
              pinBlocked={pinBlocked(row.model)}
              onDownload={() => void actions.join(row.model)}
              onJoin={() => void actions.join(row.model)}
              onPin={() => void actions.pin(row.model)}
              onUnpin={() => void actions.unpin(row.model)}
              onRemove={() => setRemove(row.model)}
            />
          ))}
        </div>
      ) : (
        <Empty title={query || filter !== 'all' ? 'No matching models' : 'No models available'}>
          {query || filter !== 'all'
            ? 'Try another name or change the filter.'
            : 'Connect to the network to load the model catalog.'}
        </Empty>
      )}
      <footer className="list-footer">
        <SlidersHorizontal size={15} />
        <span>
          {pool.length} in the pool · {status.pinned.length} pinned. Downloaded models stay on this
          Mac until removed.
        </span>
      </footer>
      {remove && (
        <RemoveModelDialog
          model={remove}
          inPool={status.selected.includes(remove.id)}
          onRemove={() => void actions.remove(remove)}
          onClose={() => setRemove(undefined)}
        />
      )}
      {confirm && (
        <AutopilotConfirm
          change={confirm}
          onConfirm={() =>
            void actions.policy(
              { action: confirm === 'pause' ? 'autopilot_pause' : 'autopilot_disable' },
              confirm === 'pause' ? 'Pausing…' : 'Turning off…',
            )
          }
          onClose={() => setConfirm(undefined)}
        />
      )}
    </>
  );
}
