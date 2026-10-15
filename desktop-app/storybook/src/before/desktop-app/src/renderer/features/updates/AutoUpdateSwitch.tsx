import { useState } from 'react';
import { ShieldCheck } from 'lucide-react';
import { Button, Modal } from '../../components/UI';

export function AutoUpdateSwitch({
  checked,
  disabled,
  onChange,
}: {
  checked: boolean;
  disabled?: boolean;
  onChange: (enabled: boolean) => void;
}) {
  const [confirm, setConfirm] = useState(false);
  return (
    <>
      <label className="setting-row">
        <span>
          <strong>Automatic provider updates</strong>
          <small>Recommended · on by default</small>
        </span>
        <input
          type="checkbox"
          role="switch"
          aria-label="Automatic provider updates"
          className="switch"
          checked={checked}
          disabled={disabled}
          onChange={(event) => (event.target.checked ? onChange(true) : setConfirm(true))}
        />
      </label>
      {confirm && (
        <Modal title="Turn off automatic updates?" onClose={() => setConfirm(false)}>
          <p>
            Not recommended. Older versions may stop receiving requests. You’ll need to install
            updates yourself.
          </p>
          <div className="dialog-actions">
            <Button variant="primary" onClick={() => setConfirm(false)}>
              <ShieldCheck size={16} /> Keep enabled
            </Button>
            <Button
              disabled={disabled}
              onClick={() => {
                setConfirm(false);
                onChange(false);
              }}
            >
              Turn off
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
