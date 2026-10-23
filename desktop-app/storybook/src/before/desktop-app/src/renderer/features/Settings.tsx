import { useState } from 'react';
import { Check } from 'lucide-react';
import type { BackendState } from '../useBackend';
import { api } from '../useBackend';
import type { Snapshot } from '../../shared/contracts';
import { Button, External, Header, Notice, Status } from '../components/UI';
import { AutoUpdateSwitch } from './updates/AutoUpdateSwitch';
import { IdleMemory } from './settings/IdleMemory';
import { idleDraft, idleMinutes } from './settings/idleDuration';
import { ScheduleEditor } from '../components/ScheduleEditor';

export function Settings({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const original = backend.state!.settings;
  const [base, setBase] = useState(original);
  const changedElsewhere = base.revision !== original.revision;
  const [name, setName] = useState(original.name);
  const [idle, setIdle] = useState(() => idleDraft(original.idle_minutes));
  const [auto, setAuto] = useState(original.auto_update);
  const [schedule, setSchedule] = useState(original.schedule || { enabled: false, windows: [] });
  const idleValue = idleMinutes(idle);
  return (
    <>
      <Header
        level={embedded ? 2 : 1}
        title="Settings"
        description="Your Mac, on your terms."
        action={
          <Button
            variant="primary"
            disabled={backend.busy || !name.trim() || changedElsewhere || idleValue === undefined}
            onClick={async () => {
              if (idleValue === undefined) return;
              if (
                await backend.act(
                  {
                    action: 'settings',
                    revision: base.revision,
                    name,
                    idle_minutes: idleValue,
                    auto_update: auto,
                    schedule,
                  },
                  true,
                )
              ) {
                const latest = await api?.read<Snapshot>('state');
                if (latest) setBase(latest.settings);
              }
            }}
          >
            Save changes <Check size={15} />
          </Button>
        }
      />
      {changedElsewhere && (
        <Notice>
          Settings changed in the backend. Reload before saving.
          <Button
            onClick={() => {
              setBase(original);
              setName(original.name);
              setIdle(idleDraft(original.idle_minutes));
              setAuto(original.auto_update);
              setSchedule(original.schedule || { enabled: false, windows: [] });
            }}
          >
            Reload settings
          </Button>
        </Notice>
      )}
      <section className="settings-section">
        <h2>This Mac</h2>
        <label className="setting-row">
          <span>
            <strong>Name</strong>
            <small>Identify this Mac in your local workspace.</small>
          </span>
          <input
            value={name}
            maxLength={80}
            onChange={(e) => setName(e.target.value)}
            aria-label="Mac name"
          />
        </label>
      </section>
      <section className="settings-section">
        <h2>Memory</h2>
        <IdleMemory value={idle} onChange={setIdle} />
        <div className="setting-row">
          <span>
            <strong>Model storage</strong>
            <small>Managed by the Swift backend.</small>
          </span>
          <code>{original.cache_path}</code>
        </div>
      </section>
      <ScheduleEditor value={schedule} onChange={setSchedule} />
      <section className="settings-section">
        <h2>Updates & background activity</h2>
        <AutoUpdateSwitch checked={auto} onChange={setAuto} disabled={backend.busy} />
        <div className="setting-row">
          <span>
            <strong>Keep providing in the background</strong>
            <small>Closing the window keeps the menu bar and provider available.</small>
          </span>
          <Status state="online">Always available</Status>
        </div>
      </section>
      <section className="settings-section">
        <h2>Account</h2>
        <div className="setting-row">
          <span>
            <strong>{backend.state!.linked ? 'This Mac is linked' : 'Link your account'}</strong>
            <small>Account linking attributes this Mac’s earnings to you.</small>
          </span>
          <Button
            disabled={backend.busy}
            onClick={() => void backend.act({ action: backend.state!.linked ? 'unlink' : 'link' })}
          >
            {backend.state!.linked ? 'Unlink this Mac' : 'Link account'}
          </Button>
        </div>
        <div className="action-row">
          <External target="console">Account & payouts</External>
          <External target="privacy">Privacy</External>
        </div>
      </section>
    </>
  );
}
