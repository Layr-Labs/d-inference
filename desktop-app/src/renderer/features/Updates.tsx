import { useEffect, useState } from 'react';
import { RotateCw } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import type { GUIUpdate } from '../../shared/contracts';
import { Button, Header } from '../components/UI';
import { AutoUpdateSwitch } from './updates/AutoUpdateSwitch';
import { ReleaseTimeline } from './updates/ReleaseTimeline';
import { RuntimeVersion } from './updates/RuntimeVersion';
import styles from './updates/updates.module.css';

export function Updates({ backend }: { backend: BackendState }) {
  const [update, setUpdate] = useState<GUIUpdate>();
  const [checking, setChecking] = useState(false);
  const [restartNeeded, setRestartNeeded] = useState(false);
  const [saving, setSaving] = useState(false);
  const error = (cause: unknown) =>
    setUpdate({
      state: 'error',
      message: cause instanceof Error ? cause.message : 'Could not check for updates.',
    });
  useEffect(() => {
    let mounted = true;
    const refresh = () => {
      void api
        ?.updateStatus()
        .then((value) => {
          if (mounted) setUpdate(value);
        })
        .catch((cause) => {
          if (mounted) error(cause);
        });
    };
    refresh();
    const timer = setInterval(refresh, 5000);
    return () => {
      mounted = false;
      clearInterval(timer);
    };
  }, []);
  async function changeAuto(auto: boolean) {
    const settings = backend.state!.settings;
    setSaving(true);
    try {
      const saved = await backend.act(
        {
          action: 'settings',
          revision: settings.revision,
          name: settings.name,
          idle_minutes: settings.idle_minutes,
          auto_update: auto,
          schedule: settings.schedule,
          startup_preload: settings.startup_preload,
        },
        true,
      );
      if (saved && backend.state!.state !== 'stopped') setRestartNeeded(true);
    } finally {
      setSaving(false);
    }
  }
  return (
    <>
      <Header
        title="Updates"
        description="Stay current. Keep contributing."
        action={
          <Button
            disabled={checking}
            onClick={async () => {
              setChecking(true);
              try {
                setUpdate((await api?.checkUpdate()) || { state: 'idle' });
                await backend.refresh();
              } catch (cause) {
                error(cause);
              } finally {
                setChecking(false);
              }
            }}
          >
            <RotateCw size={15} /> {checking ? 'Checking…' : 'Check for updates'}
          </Button>
        }
      />
      <RuntimeVersion backend={backend} />
      <section className={styles.auto}>
        <AutoUpdateSwitch
          checked={backend.state!.settings.auto_update}
          disabled={backend.busy || saving}
          onChange={(value) => void changeAuto(value)}
        />
        <small className={styles.muted}>
          Preference changes apply on the next provider restart.
        </small>
        {restartNeeded && (
          <div className={styles.restart} role="status">
            <span>Saved. Restart the provider to apply.</span>
            <Button
              disabled={backend.busy}
              onClick={async () => {
                if (await backend.act({ action: 'restart' }, true)) setRestartNeeded(false);
              }}
            >
              Restart provider
            </Button>
          </div>
        )}
      </section>
      <ReleaseTimeline
        history={backend.releaseHistory}
        latest={backend.release}
        installed={backend.state!.version}
      />
      <section className={styles.desktop}>
        <h2>Desktop app</h2>
        <p>
          {!update
            ? 'Checking desktop update status…'
            : update.state === 'ready'
              ? `Version ${update.version} is ready.`
              : update.state === 'downloading'
                ? 'Downloading the desktop update…'
                : update.state === 'error' || update.state === 'unconfigured'
                  ? update.message
                  : 'The desktop app checks for updates automatically.'}
        </p>
        {update?.state === 'ready' && (
          <>
            <Button
              variant="primary"
              onClick={() => {
                void api?.applyUpdate().catch(error);
              }}
            >
              Restart desktop app
            </Button>
            <small>Your provider keeps running.</small>
          </>
        )}
      </section>
    </>
  );
}
