import { useState } from 'react';
import { Check, Copy, Play, Terminal } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import { Button, Header, Status } from '../components/UI';

export function Studio({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const state = backend.state!;
  const [mode, setMode] = useState('combined');
  const [key, setKey] = useState<string>();
  const [copied, setCopied] = useState(false);
  const models = state.models.filter((model) => model.downloaded && model.eligible);
  const [selected, setSelected] = useState('');
  const model = selected || models[0]?.id || '';
  const endpoint = state.endpoint;
  const copy = async (value: string) => {
    await api?.copy(value);
    setCopied(true);
    setTimeout(() => setCopied(false), 1600);
  };
  const curl = `curl ${endpoint?.base_url || 'http://127.0.0.1:8000/v1'}/chat/completions \\\n  -H 'Authorization: Bearer <your-local-api-key>' \\\n  -H 'Content-Type: application/json' \\\n  -d '${JSON.stringify({ model, messages: [{ role: 'user', content: 'Hello' }] })}'`;
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Studio"
        description="Use the models on your Mac in your own applications."
        action={<span className="tag">Local API</span>}
      />
      <div className="studio-intro">
        <Terminal size={32} strokeWidth={1.2} />
        <div>
          <h2>Your Mac. Your endpoint.</h2>
          <p>OpenAI-compatible inference, backed by the same Swift runtime.</p>
        </div>
        {endpoint && <Status state="online">Listening</Status>}
      </div>
      <section className="settings-section">
        <h2>Serving mode</h2>
        <div className="mode-options">
          <label className={mode === 'combined' ? 'selected' : ''}>
            <input
              type="radio"
              name="mode"
              checked={mode === 'combined'}
              onChange={() => setMode('combined')}
            />
            <strong>Alongside the network</strong>
            <span>Reuse models while contributing to Darkbloom.</span>
          </label>
          <label className={mode === 'local' ? 'selected' : ''}>
            <input
              type="radio"
              name="mode"
              checked={mode === 'local'}
              onChange={() => setMode('local')}
            />
            <strong>Local only</strong>
            <span>Serve your applications without joining the network.</span>
          </label>
        </div>
        <label className="setting-row">
          <span>
            <strong>Model</strong>
            <small>Choose a downloaded model.</small>
          </span>
          <select value={model} onChange={(e) => setSelected(e.target.value)}>
            <option value="" disabled>
              Choose a model
            </option>
            {models.map((model) => (
              <option key={model.id} value={model.id}>
                {model.display_name}
              </option>
            ))}
          </select>
        </label>
        <Button
          variant="primary"
          disabled={!model || backend.busy}
          onClick={() =>
            void backend.act({
              action: 'start',
              models: [model],
              local: mode === 'local',
              endpoint: true,
            })
          }
        >
          <Play size={14} /> {endpoint ? 'Apply serving mode' : 'Enable local endpoint'}
        </Button>
      </section>
      <section className="settings-section">
        <h2>Connection details</h2>
        <div className="setting-row">
          <span>Base URL</span>
          <code>{endpoint?.base_url || 'Not enabled'}</code>
          {endpoint && (
            <button
              className="icon-button"
              aria-label="Copy base URL"
              onClick={() => void copy(endpoint.base_url)}
            >
              <Copy size={16} />
            </button>
          )}
        </div>
        <div className="setting-row">
          <span>API key</span>
          <code>{key || '••••••••••••••••'}</code>
          <Button
            disabled={!endpoint}
            onClick={async () => {
              if (key) setKey(undefined);
              else setKey((await api?.read<{ key: string }>('endpoint-key'))?.key);
            }}
          >
            {key ? 'Hide' : 'Reveal'}
          </Button>
        </div>
        <small className="muted">Authenticated and bound to this Mac’s loopback interface.</small>
      </section>
      <section className="section">
        <div className="section-title">
          <h2>Make a request</h2>
          <Button disabled={!endpoint} onClick={() => void copy(curl)}>
            {copied ? <Check size={15} /> : <Copy size={15} />} {copied ? 'Copied' : 'Copy example'}
          </Button>
        </div>
        <pre className="code-block">{curl}</pre>
      </section>
    </>
  );
}
