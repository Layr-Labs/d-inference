import { useState } from 'react';
import { Undo2 } from 'lucide-react';
import type { BackendState } from '../../useBackend';
import { supports } from '../../capabilities';
import { Button, Modal } from '../../components/UI';
import { runtimeVersion } from './version';
import styles from './updates.module.css';

// `darkbloom update --rollback`, from a runtime that offers it: back to the release this Mac kept
// for rollback, asked first as the CLI asks. The runtime refuses, with its reason, when there is
// none to go back to.
export function Rollback({ backend }: { backend: BackendState }) {
  const [confirm, setConfirm] = useState(false);
  const state = backend.state!;
  if (!supports(state, 'update_rollback')) return null;
  const installed = runtimeVersion(state);
  return (
    <>
      <div className={`setting-row ${styles.rollback}`}>
        <span>
          <strong>Previous release</strong>
          <small>Kept on this Mac for rollback.</small>
        </span>
        <Button disabled={backend.busy} onClick={() => setConfirm(true)}>
          <Undo2 size={15} /> Return to the previous release
        </Button>
      </div>
      {confirm && (
        <Modal title="Return to the previous release?" onClose={() => setConfirm(false)}>
          <p>
            This Mac returns to the release kept for rollback once its requests finish. Automatic
            updates then skip {installed}; the next newer release installs normally.
          </p>
          <div className="dialog-actions">
            <Button onClick={() => setConfirm(false)}>Keep this release</Button>
            <Button
              variant="primary"
              disabled={backend.busy}
              onClick={() => {
                setConfirm(false);
                void backend.act({ action: 'update_rollback' });
              }}
            >
              <Undo2 size={15} /> Roll back
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
