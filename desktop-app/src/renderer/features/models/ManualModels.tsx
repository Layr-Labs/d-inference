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

const filters = [
  { id: 'all', label: 'All' },
  { id: 'downloaded', label: 'Downloaded' },
  { id: 'serving', label: 'Serving' },
] as const;
type Filter = (typeof filters)[number]['id'];

// Manual selection: the chosen downloaded models serve once applied.
export function ManualModels({
  backend,
  embedded,
  note,
  ranked,
  earnings,
  order,
}: {
  backend: BackendState;
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
  const chosen =
    selection || state.models.filter((model) => model.serving).map((model) => model.id);
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
        description="Choose the intelligence your Mac brings to the grid."
        action={
          <Button
            variant="primary"
            disabled={backend.busy || !chosen.length}
            onClick={() =>
              void backend.act({ action: running ? 'switch' : 'start', models: chosen })
            }
          >
            {running ? 'Apply selection' : 'Start providing'} <Check size={16} />
          </Button>
        }
      />
      {state.catalog_error && <Notice>{state.catalog_error}</Notice>}
      {note}
      <div className="model-memory">
        <div>
          <span className="muted">Native load allowance</span>
          <strong>{gb(state.memory.free_for_load_gb)}</strong>
        </div>
        <div className="memory-track">
          <span
            style={{
              width: `${Math.min(100, ((state.memory.active_gb || 0) / (state.memory.total_gb || 1)) * 100)}%`,
            }}
          />
        </div>
        <p>
          {gb(state.memory.total_gb)} unified memory
          <br />
          <span className="muted">The runtime checks each load before allocating.</span>
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
        <div className="model-list">
          {models.map((model) => (
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
                <p>{model.description || model.id}</p>
                <details className="model-extra">
                  <summary>Model details</summary>
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
                      disabled={model.serving || model.loaded || backend.busy}
                      onClick={() => setRemove(model)}
                    >
                      <Trash2 size={16} />
                    </button>
                  </>
                ) : (
                  <Button
                    disabled={backend.busy}
                    onClick={() => void backend.act({ action: 'download', model: model.id })}
                  >
                    <Download size={15} /> Download
                  </Button>
                )}
              </div>
            </article>
          ))}
        </div>
      ) : (
        <Empty title={query ? 'No matching models' : 'No models available'}>
          {query
            ? 'Try another name or change the filter.'
            : 'Connect to the network to load the model catalog.'}
        </Empty>
      )}
      <footer className="list-footer">
        <SlidersHorizontal size={15} />
        <span>
          {chosen.length} selected for serving. Downloaded models remain on disk until removed.
        </span>
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
