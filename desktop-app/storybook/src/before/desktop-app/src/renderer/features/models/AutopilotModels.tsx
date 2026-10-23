import { useState, type ReactNode } from 'react';
import type { ModelEarnings } from './earnings';
import { Check, SlidersHorizontal } from 'lucide-react';
import type { NativeModel } from '../../../shared/contracts';
import { Button, Empty, Header, Modal, Notice } from '../../components/UI';
import { LinkPanel } from '../../components/onboarding/LinkPanel';
import { networkEarnings, recommendedModels, rankNetworkModels } from './recommendations';
import { RecommendedModels } from './RecommendedModels';
import { enableAction } from './TurnOnAutopilot';
import { pinnedMemory } from '../../models/selection';
import type { BackendState } from '../../useBackend';
import { AutopilotCard } from './AutopilotCard';
import { AutopilotConfirm, type AutopilotChange } from './AutopilotConfirm';
import { matchesQuery, ModelToolbar } from './ModelToolbar';
import { inFilter, poolFilters, poolState, runningDownload, type PoolFilter } from './pool';
import { PoolRow } from './PoolRow';
import { RemoveModelDialog } from './RemoveModelDialog';
import type { ModelActions } from './useModelActions';
import { ExpandableModelList } from './ExpandableModelList';

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
  const [filter, setFilter] = useState<PoolFilter>('pool');
  const [remove, setRemove] = useState<NativeModel>();
  const [confirm, setConfirm] = useState<AutopilotChange>();
  const network = networkEarnings(backend.network);
  const recommended = recommendedModels(state.models, network);
  const ranked =
    filter === 'all' || filter === 'available' ? rankNetworkModels(models, network) : models;
  const rows = ranked.map((model) => {
    const download = runningDownload(state, model.id, actions.downloads);
    return { model, download, state: poolState(model, status, !!download) };
  });
  const shown = rows.filter(
    (row) =>
      matchesQuery(row.model, query) &&
      (filter === 'pool'
        ? row.model.downloaded || row.state === 'downloading'
        : inFilter(row.state, filter)),
  );
  const start = enableAction(state);
  const busy = backend.busy || Object.keys(actions.working).length > 0;
  const cancelLink = () => {
    const linking = state.operations.find(
      (operation) => operation.action === 'link' && operation.state === 'running',
    );
    if (linking?.cancellable) void backend.act({ action: 'cancel', operation: linking.id });
  };
  const pinBlocked = (model: NativeModel) =>
    pinnedMemory(state, [...status.pinned, model.id]).exceeds
      ? 'Pinning this needs more memory than this Mac has.'
      : undefined;
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Models"
        action={
          state.autopilot?.enabled &&
          state.state !== 'running' && (
            <Button
              variant="primary"
              disabled={busy || !start.models.length}
              onClick={() => void actions.policy(start, 'Starting…')}
            >
              Start serving <Check size={16} />
            </Button>
          )
        }
      />
      {state.catalog_error && <Notice>{state.catalog_error}</Notice>}
      {actions.problem && <Notice onClose={actions.dismiss}>{actions.problem}</Notice>}
      {status.enabled ? (
        <AutopilotCard
          snapshot={state}
          working={actions.working.autopilot}
          busy={busy}
          onPause={() => setConfirm('pause')}
          onResume={() => void actions.policy({ action: 'autopilot_resume' }, 'Resuming…')}
          onTurnOff={() => setConfirm('disable')}
          onRefresh={() => void actions.policy({ action: 'autopilot_models' }, 'Refreshing…')}
        />
      ) : (
        <div className="toolbar">
          <strong>Autopilot</strong>
          <span className="muted">Ready to start</span>
          <Button
            disabled={busy || !start.models.length}
            onClick={() => void actions.policy(enableAction(state), 'Starting…')}
          >
            Turn on Autopilot
          </Button>
        </div>
      )}
      <RecommendedModels
        snapshot={state}
        models={status.enabled ? recommended.filter((model) => !model.downloaded) : recommended}
        earnings={network}
        actions={actions}
        setup={!status.enabled}
        busy={busy}
      />
      <ModelToolbar
        filters={poolFilters}
        filter={filter}
        onFilter={setFilter}
        query={query}
        onQuery={setQuery}
      />
      {filter === 'all' || filter === 'available' ? (
        <div className="model-earnings-order">
          <span>Network earnings · 7 days</span>
          {!network && <span className="muted">Unavailable</span>}
        </div>
      ) : (
        order
      )}
      {shown.length ? (
        <ExpandableModelList items={shown} key={`${filter}:${query}`}>
          {(row) => (
            <PoolRow
              key={row.model.id}
              model={row.model}
              earnings={earnings}
              networkEarnings={filter === 'all' || filter === 'available' ? network : undefined}
              busy={busy}
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
          )}
        </ExpandableModelList>
      ) : !query && filter === 'pool' ? (
        <Empty title="No downloaded models">
          <Button onClick={() => setFilter('all')}>Browse models</Button>
        </Empty>
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
          {state.models.filter((model) => model.downloaded).length} downloaded ·{' '}
          {status.pinned.length} kept in memory
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
      {state.link && (
        <Modal title="Link this Mac" onClose={cancelLink}>
          <LinkPanel link={state.link} cancel={cancelLink} />
        </Modal>
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
