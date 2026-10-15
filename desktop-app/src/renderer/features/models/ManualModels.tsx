import { useMemo, useState, type ReactNode } from 'react';
import { Check, Download, SlidersHorizontal, Trash2 } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { Button, Empty, Header, Notice, Status } from '../../components/UI';
import { compact, gb } from '../../format';
import type { NativeModel } from '../../../shared/contracts';
import { ModelGlyph } from './ModelGlyph';
import { matchesQuery, ModelToolbar } from './ModelToolbar';
import { RemoveModelDialog } from './RemoveModelDialog';
import { ModelEarningsAmount } from './ModelEarnings';
import type { ModelEarnings } from './earnings';
import { ExpandableModelList } from './ExpandableModelList';

const filters = [
  { id: 'all', label: 'All' },
  { id: 'downloaded', label: 'Downloaded' },
  { id: 'serving', label: 'Serving' },
] as const;
type Filter = (typeof filters)[number]['id'];

// Manual selection: the chosen downloaded models serve once applied.
export function ManualModels({
  backend,
  busy,
  embedded,
  note,
  ranked,
  earnings,
  order,
}: {
  backend: BackendState;
  // The app or a model action, such as turning Autopilot on, is busy.
  busy: boolean;
  embedded: boolean;
  note?: ReactNode;
  ranked: NativeModel[];
  earnings: ModelEarnings;
  order: ReactNode;
}) {
  const state = backend.state!;
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [selection, setSelection] = useState<string[] | null>(null);
  const [remove, setRemove] = useState<NativeModel>();
  // A chosen model that is removed (or never finished downloading) can no longer serve, so it
  // leaves the selection rather than staying checked, disabled and submitted.
  const onDisk = new Set(state.models.filter((model) => model.downloaded).map((model) => model.id));
  const chosen = (
    selection || state.models.filter((model) => model.serving).map((model) => model.id)
  ).filter((id) => onDisk.has(id));
  const models = useMemo(
    () =>
      ranked.filter(
        (model) =>
          matchesQuery(model, query) &&
          (filter === 'all' || (filter === 'downloaded' ? model.downloaded : model.serving)),
      ),
    [ranked, filter, query],
  );
  const running = state.state === 'running';
  const toggle = (id: string) =>
    setSelection(chosen.includes(id) ? chosen.filter((value) => value !== id) : [...chosen, id]);
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Models"
        action={
          <Button
            variant="primary"
            disabled={busy || !chosen.length}
            onClick={() =>
              void backend.act({ action: running ? 'switch' : 'start', models: chosen })
            }
          >
            {running ? 'Apply selection' : 'Start serving'} <Check size={16} />
          </Button>
        }
      />
      {state.catalog_error && <Notice>{state.catalog_error}</Notice>}
      {note}
      <div className="model-memory">
        <div>
          <span className="muted">Memory available for models</span>
          <strong>{gb(state.memory.free_for_load_gb)}</strong>
        </div>
        {/* Unreported usage is not drawn as an empty (0%) bar. */}
        {state.memory.active_gb != null && state.memory.total_gb > 0 && (
          <div className="memory-track">
            <span
              style={{
                width: `${Math.min(100, (state.memory.active_gb / state.memory.total_gb) * 100)}%`,
              }}
            />
          </div>
        )}
        <p>
          {state.memory.total_gb > 0
            ? `${gb(state.memory.total_gb)} unified memory`
            : 'Unified memory unknown'}
        </p>
      </div>
      <ModelToolbar
        filters={filters}
        filter={filter}
        onFilter={setFilter}
        query={query}
        onQuery={setQuery}
      />
      {order}
      {models.length ? (
        <ExpandableModelList items={models} key={`${filter}:${query}`}>
          {(model) => (
            <article
              className={`model-row ${chosen.includes(model.id) ? 'chosen' : ''}`}
              key={model.id}
            >
              <label className="model-selection">
                <input
                  type="checkbox"
                  aria-label={`Select ${model.display_name}`}
                  checked={chosen.includes(model.id)}
                  disabled={!model.downloaded || !model.eligible}
                  onChange={() => toggle(model.id)}
                />
                <span />
              </label>
              <ModelGlyph name={model.display_name} />
              <div className="model-description">
                <div>
                  <h3>{model.display_name}</h3>
                  {model.loaded && <Status state="online">In memory</Status>}
                </div>
                <details className="model-extra">
                  <summary>Model details</summary>
                  <p>{model.description || model.id}</p>
                  <div className="model-meta">
                    <span>{gb(model.size_gb)} download</span>
                    {model.memory_gb && <span>{gb(model.memory_gb)} load estimate</span>}
                    {model.context_length && <span>{compact(model.context_length)} context</span>}
                    {model.quantization && <span>{model.quantization}</span>}
                  </div>
                </details>
                {model.reason && <small className="warning-text">{model.reason}</small>}
              </div>
              <ModelEarningsAmount model={model.id} earnings={earnings} />
              <div className="model-actions">
                {model.downloaded ? (
                  <>
                    <span className="muted">
                      <Check size={14} /> Downloaded
                    </span>
                    <button
                      className="icon-button"
                      aria-label={`Remove ${model.display_name}`}
                      disabled={model.serving || model.loaded || busy}
                      onClick={() => setRemove(model)}
                    >
                      <Trash2 size={16} />
                    </button>
                  </>
                ) : (
                  <Button
                    // A model this Mac can't run (its reason is shown above) isn't offered for
                    // download; Autopilot's view treats it as not available the same way.
                    disabled={busy || !model.eligible}
                    title={
                      model.eligible ? undefined : (model.reason ?? 'Not available on this Mac')
                    }
                    onClick={() => void backend.act({ action: 'download', model: model.id })}
                  >
                    <Download size={15} /> Download
                  </Button>
                )}
              </div>
            </article>
          )}
        </ExpandableModelList>
      ) : (
        <Empty
          title={
            query
              ? 'No matching models'
              : !ranked.length
                ? 'No models available'
                : filter === 'downloaded'
                  ? 'No downloaded models'
                  : 'No models serving'
          }
        >
          {query
            ? 'Try another name or change the filter.'
            : !ranked.length
              ? 'Connect to the network to load the model catalog.'
              : filter === 'downloaded'
                ? 'Download a model to choose it for serving.'
                : 'Choose downloaded models and apply the selection.'}
        </Empty>
      )}
      <footer className="list-footer">
        <SlidersHorizontal size={15} />
        <span>{chosen.length} selected for serving</span>
      </footer>
      {remove && (
        <RemoveModelDialog
          model={remove}
          onRemove={() => void backend.act({ action: 'remove', model: remove.id })}
          onClose={() => setRemove(undefined)}
        />
      )}
    </>
  );
}
