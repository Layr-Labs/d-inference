import { useMemo, useState } from 'react';
import { Check, Download, Search, SlidersHorizontal, Trash2 } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { Button, Empty, Header, Modal, Notice, Status } from '../components/UI';
import { compact, gb } from '../format';
import type { NativeModel } from '../../shared/contracts';

export function Models({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const state = backend.state!;
  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState('all');
  const [selection, setSelection] = useState<string[] | null>(null);
  const [remove, setRemove] = useState<NativeModel>();
  const chosen =
    selection || state.models.filter((model) => model.serving).map((model) => model.id);
  const models = useMemo(
    () =>
      state.models.filter(
        (model) =>
          `${model.display_name} ${model.id} ${model.family}`
            .toLowerCase()
            .includes(query.toLowerCase()) &&
          (filter === 'all' || (filter === 'downloaded' ? model.downloaded : model.serving)),
      ),
    [state.models, filter, query],
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
      <div className="toolbar">
        <div className="segmented" aria-label="Filter models">
          {['all', 'downloaded', 'serving'].map((value) => (
            <button
              className={filter === value ? 'selected' : ''}
              key={value}
              onClick={() => setFilter(value)}
            >
              {value[0].toUpperCase() + value.slice(1)}
            </button>
          ))}
        </div>
        <label className="search">
          <Search size={16} />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search models"
            aria-label="Search models"
          />
        </label>
      </div>
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
              <div className="model-glyph">
                {model.display_name.startsWith('GPT')
                  ? '◎'
                  : model.display_name.startsWith('Gemma')
                    ? '✧'
                    : 'Q'}
              </div>
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
        <Modal title={`Remove ${remove.display_name}?`} onClose={() => setRemove(undefined)}>
          <p>This deletes the downloaded model from this Mac. You can download it again later.</p>
          <div className="dialog-actions">
            <Button onClick={() => setRemove(undefined)}>Keep model</Button>
            <Button
              variant="danger"
              onClick={() => {
                void backend.act({ action: 'remove', model: remove.id });
                setRemove(undefined);
              }}
            >
              Remove model
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
