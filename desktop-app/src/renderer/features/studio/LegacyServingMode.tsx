import { useState } from 'react';
import { Play } from 'lucide-react';
import type { NativeModel } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import styles from './studio.module.css';

// A runtime without local-first serving: its two ways to serve a local API, as before.
export function LegacyServingMode({
  backend,
  models,
  model,
  onModel,
}: {
  backend: BackendState;
  models: NativeModel[];
  model: string;
  onModel: (id: string) => void;
}) {
  const [mode, setMode] = useState('combined');
  return (
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
          <span>Reuse models while serving the Darkbloom network.</span>
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
        <select value={model} onChange={(e) => onModel(e.target.value)}>
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
        <Play size={14} />{' '}
        {backend.state!.endpoint ? 'Apply serving mode' : 'Enable local endpoint'}
      </Button>
      <p className={styles.note}>
        A newer Darkbloom CLI adds me first, request routing and tool setup.
      </p>
    </section>
  );
}
