import { useState, type CSSProperties, type ReactNode } from 'react';
import { Pause, Play, ScrollText, SlidersHorizontal, Wrench } from 'lucide-react';
import type { SandboxAction, SandboxStatus } from '../../../shared/sandbox';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { PauseDialog, SlotsDialog, UninstallDialog } from './SandboxDialogs';
import { SandboxLogs } from './SandboxLogs';
import {
  changesSlots,
  diskSlots,
  explanation,
  gib,
  headline,
  imageState,
  jobsRunning,
  nextStep,
  platformName,
  reportsSlots,
  shownDisks,
  slots,
  updateCheck,
  type PlatformSlots,
} from './status';
import styles from './sandboxes.module.css';

type Dialog = 'pause' | 'uninstall' | 'slots';

// The installed add-on: its state and what that means for inference, slots, images and work
// disks, and the controls `darkbloom sandbox` offers.
export function SandboxStatusCard({
  status,
  backend,
  refresh,
}: {
  status: SandboxStatus;
  backend: BackendState;
  refresh: () => Promise<void>;
}) {
  const [dialog, setDialog] = useState<Dialog>();
  const [logs, setLogs] = useState(false);
  const run = (action: SandboxAction, wait = true) => void backend.act(action, wait);
  const unreadable = !!status.error;
  const { text, tone } = unreadable
    ? { text: 'Status unavailable', tone: 'fail' as const }
    : headline(status);
  const step = nextStep(status);
  const busy = backend.busy;
  const platforms = slots(status);
  const images = status.images ?? [];
  const disks = shownDisks(status);
  const reporting = !unreadable && reportsSlots(status);
  const cells = [
    ...(reporting ? platforms.map((item) => <SlotsCell key={item.platform} slots={item} />) : []),
    ...(!reporting && !unreadable && platforms.length
      ? [
          <Cell key="totals" label="Jobs at a time">
            <strong>{platforms.map((item) => `${item.platform} ${item.total}`).join(', ')}</strong>
          </Cell>,
        ]
      : []),
    ...(!unreadable && (reporting || jobsRunning(status) > 0)
      ? [
          <Cell key="jobs" label="Jobs running">
            <strong>{jobsRunning(status)}</strong>
          </Cell>,
        ]
      : []),
    ...(!unreadable && images.length
      ? [
          <Cell key="images" label="Images">
            <ul className={styles.images}>
              {images.map((image) => (
                <li key={image.platform} data-state={image.state}>
                  <span>{platformName(image.platform)}</span>
                  <span>{imageState(image)}</span>
                  {image.state === 'downloading' && image.progress != null && (
                    <span className={styles.bar} aria-hidden>
                      <i style={{ width: `${Math.min(Math.max(image.progress, 0), 1) * 100}%` }} />
                    </span>
                  )}
                </li>
              ))}
            </ul>
          </Cell>,
        ]
      : []),
  ];
  const meta = [
    status.version && `Darkbloom Sandbox ${status.version}`,
    status.host_id && `Host ${status.host_id}`,
    !unreadable && updateCheck(status),
  ].filter((item): item is string => !!item);
  return (
    <>
      <section className={styles.status} aria-label="Darkbloom Sandbox status">
        <div className={styles.statusHead}>
          <span className={styles.tone} data-tone={tone} aria-hidden />
          <div>
            <h2>{text}</h2>
            <p>{unreadable ? status.error : explanation(status)}</p>
          </div>
        </div>
        <div className={styles.actions}>
          {unreadable ? (
            <>
              <Button variant="primary" onClick={() => void refresh()}>
                Try again
              </Button>
              <Button disabled={busy} onClick={() => run({ action: 'sandbox_setup' }, false)}>
                <Wrench size={14} /> Repair
              </Button>
            </>
          ) : step === 'resume' ? (
            <Button
              variant="primary"
              disabled={busy}
              onClick={() => run({ action: 'sandbox_resume' })}
            >
              <Play size={14} /> Resume
            </Button>
          ) : step === 'continue' ? (
            <Button
              variant="primary"
              disabled={busy}
              onClick={() => run({ action: 'sandbox_setup' }, false)}
            >
              Continue setup
            </Button>
          ) : step === 'repair' ? (
            <Button
              variant="primary"
              disabled={busy}
              onClick={() => run({ action: 'sandbox_setup' }, false)}
            >
              <Wrench size={14} /> Repair
            </Button>
          ) : (
            <Button disabled={busy} onClick={() => setDialog('pause')}>
              <Pause size={14} /> Pause
            </Button>
          )}
          {!unreadable && changesSlots(status) && platforms.length > 0 && (
            <Button disabled={busy} onClick={() => setDialog('slots')}>
              <SlidersHorizontal size={14} /> Change jobs at a time
            </Button>
          )}
          <Button
            variant="quiet"
            aria-expanded={logs}
            aria-controls="sandbox-logs"
            onClick={() => setLogs((open) => !open)}
          >
            <ScrollText size={14} /> Logs
          </Button>
          {status.installed !== false && (
            <Button
              variant="danger"
              className={styles.end}
              disabled={busy}
              onClick={() => setDialog('uninstall')}
            >
              Uninstall
            </Button>
          )}
        </div>
        {cells.length > 0 && (
          <div className={styles.cells} style={{ '--cells': cells.length } as CSSProperties}>
            {cells}
          </div>
        )}
        {!unreadable && disks.length > 0 && (
          <div className={styles.disks}>
            <h3>Work disks</h3>
            <ul>
              {disks.map((disk) => (
                <li key={disk.path} data-state={disk.state}>
                  <span className={styles.diskPath}>
                    <code>{disk.path}</code>
                    {disk.root_volume && <small>Internal</small>}
                  </span>
                  <span className={styles.diskFacts}>
                    <span className={styles.diskState}>
                      <i aria-hidden />
                      {disk.state.charAt(0).toUpperCase() + disk.state.slice(1)}
                    </span>
                    {disk.free_bytes != null && <span>{gib(disk.free_bytes)} free</span>}
                    {diskSlots(disk) && <span>{diskSlots(disk)}</span>}
                  </span>
                  {disk.state !== 'online' && disk.detail && <small>{disk.detail}</small>}
                </li>
              ))}
            </ul>
          </div>
        )}
        {meta.length > 0 && (
          <footer className={styles.meta}>
            {meta.map((item) => (
              <span key={item}>{item}</span>
            ))}
          </footer>
        )}
      </section>
      {logs && <SandboxLogs id="sandbox-logs" />}
      {dialog === 'pause' && (
        <PauseDialog
          onPause={() => run({ action: 'sandbox_pause' })}
          onClose={() => setDialog(undefined)}
        />
      )}
      {dialog === 'uninstall' && (
        <UninstallDialog
          status={status}
          onUninstall={() => run({ action: 'sandbox_uninstall' })}
          onClose={() => setDialog(undefined)}
        />
      )}
      {dialog === 'slots' && (
        <SlotsDialog
          status={status}
          onApply={(counts) => run({ action: 'sandbox_setup', ...counts }, false)}
          onClose={() => setDialog(undefined)}
        />
      )}
    </>
  );
}

function Cell({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className={styles.cell}>
      <span className={styles.cellLabel}>{label}</span>
      {children}
    </div>
  );
}

// Free slots of one platform: a segment per slot, filled while a job runs in it.
function SlotsCell({ slots }: { slots: PlatformSlots }) {
  const busy = slots.total - slots.free;
  const value = `${slots.free} of ${slots.total} free`;
  return (
    <Cell label={`${slots.platform} slots`}>
      <strong>{value}</strong>
      <span
        className={styles.slots}
        role="meter"
        aria-label={`${slots.platform} slots`}
        aria-valuemin={0}
        aria-valuemax={slots.total}
        aria-valuenow={slots.free}
        aria-valuetext={value}
      >
        {Array.from({ length: slots.total }, (_, index) => (
          <i key={index} data-busy={index < busy || undefined} />
        ))}
      </span>
    </Cell>
  );
}
