import { useState } from 'react';
import { Download, RotateCw } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import type { GUIUpdate } from '../../shared/contracts';
import { Button, External, Header, Notice, Status } from '../components/UI';

export function Updates({ backend }: { backend: BackendState }) {
  const [update, setUpdate] = useState<GUIUpdate>({ state: 'idle' });
  return (
    <>
      <Header
        title="Updates"
        description="The latest improvements, delivered automatically."
        action={
          <Button
            onClick={async () => {
              setUpdate((await api?.checkUpdate()) || { state: 'idle' });
              await backend.refresh();
            }}
          >
            <RotateCw size={15} /> Check for updates
          </Button>
        }
      />
      <section className="version-panel">
        <div className="version-symbol">✳</div>
        <div>
          <span className="muted">Darkbloom runtime</span>
          <h2>{backend.state!.version}</h2>
          <Status state="online">
            {backend.state!.settings.auto_update
              ? 'Automatic updates enabled'
              : 'Automatic updates disabled'}
          </Status>
        </div>
        <Button disabled={backend.busy} onClick={() => void backend.act({ action: 'update' })}>
          <Download size={15} /> Update runtime
        </Button>
      </section>
      <section className="settings-section">
        <h2>Latest runtime release</h2>
        {backend.release?.error ? (
          <Notice>{backend.release.error}</Notice>
        ) : (
          <>
            <div className="section-title">
              <strong>{backend.release?.version || 'Checking…'}</strong>
              <span className="muted">
                {backend.release?.published_at
                  ? new Date(backend.release.published_at).toLocaleDateString()
                  : ''}
              </span>
            </div>
            <p className="release-notes">
              {backend.release?.notes ||
                'Verified runtime updates are installed by the native updater. Your provider drains accepted work before activation.'}
            </p>
          </>
        )}
      </section>
      <section className="settings-section">
        <h2>Desktop app</h2>
        <p>
          {update.state === 'ready'
            ? `Version ${update.version} is ready.`
            : update.state === 'downloading'
              ? 'Downloading the desktop update…'
              : update.state === 'error'
                ? update.message
                : 'The desktop app checks for updates automatically.'}
        </p>
        {update.state === 'ready' && (
          <Button variant="primary" onClick={() => void api?.applyUpdate()}>
            Restart desktop app
          </Button>
        )}
        <p className="muted">Restarting the desktop app keeps the provider running.</p>
      </section>
      <External target="community">Release discussions</External>
    </>
  );
}
