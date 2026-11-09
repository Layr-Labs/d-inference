import { useState } from 'react';
import type { SandboxStatus } from '../../../shared/sandbox';
import { Button, Modal } from '../../components/UI';
import { SlotInputs } from './SetupForm';
import { slotCounts } from './setup';
import { jobs, jobsRunning } from './status';
import styles from './sandboxes.module.css';

// `darkbloom sandbox pause`: running jobs finish, no new jobs.
export function PauseDialog({ onPause, onClose }: { onPause: () => void; onClose: () => void }) {
  return (
    <Modal title="Pause Darkbloom Sandbox?" onClose={onClose}>
      <p>Running jobs finish; no new jobs start until you resume.</p>
      <div className="dialog-actions">
        <Button onClick={onClose}>Keep taking jobs</Button>
        <Button
          variant="primary"
          onClick={() => {
            onPause();
            onClose();
          }}
        >
          Pause
        </Button>
      </div>
    </Modal>
  );
}

// `darkbloom sandbox uninstall --yes`: running jobs end, unpaid.
export function UninstallDialog({
  status,
  onUninstall,
  onClose,
}: {
  status: SandboxStatus;
  onUninstall: () => void;
  onClose: () => void;
}) {
  const running = jobsRunning(status);
  return (
    <Modal title="Uninstall Darkbloom Sandbox?" onClose={onClose}>
      <p>This removes the add-on and its files from this Mac. Running jobs end and aren’t paid.</p>
      {running > 0 && (
        <p className={styles.dialogWarning}>
          {jobs(running)} running now. Pause first, and uninstall once{' '}
          {running === 1 ? 'it finishes' : 'they finish'}.
        </p>
      )}
      <div className="dialog-actions">
        <Button onClick={onClose}>Cancel</Button>
        <Button
          variant="danger"
          onClick={() => {
            onUninstall();
            onClose();
          }}
        >
          Uninstall
        </Button>
      </div>
    </Modal>
  );
}

// Setup again with new counts. The installer refuses while a job runs and changes nothing.
export function SlotsDialog({
  status,
  onApply,
  onClose,
}: {
  status: SandboxStatus;
  onApply: (counts: { linux_slots: number; macos_slots: number }) => void;
  onClose: () => void;
}) {
  const [linux, setLinux] = useState(String(status.slots?.linux?.total ?? 0));
  const [macos, setMacos] = useState(String(status.slots?.macos?.total ?? 0));
  const { counts, error } = slotCounts(linux, macos);
  const running = jobsRunning(status);
  return (
    <Modal title="Jobs at a time" onClose={onClose}>
      <form
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          if (!counts || running > 0) return;
          onApply(counts);
          onClose();
        }}
      >
        <p>Setup reinstalls the add-on with these counts.</p>
        <SlotInputs
          linux={linux}
          macos={macos}
          error={error}
          onChange={(next) => {
            if (next.linux !== undefined) setLinux(next.linux);
            if (next.macos !== undefined) setMacos(next.macos);
          }}
        />
        {running > 0 && (
          <p className={styles.dialogWarning}>
            A job is running, and the installer changes nothing while one runs. Pause, then change
            this once {running === 1 ? 'it finishes' : 'they finish'}.
          </p>
        )}
        <div className="dialog-actions">
          <Button type="button" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={!counts || running > 0}>
            Apply
          </Button>
        </div>
      </form>
    </Modal>
  );
}
