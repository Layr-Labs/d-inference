import { Check, LoaderCircle, X } from 'lucide-react';
import { createPortal } from 'react-dom';
import type { Operation } from '../../../shared/contracts';
import { GetHelp } from '../Help';

export function OperationToast({
  state,
  title,
  message,
  onCancel,
  onClose,
}: {
  state: Operation['state'];
  title: string;
  message: string;
  onCancel?: () => void;
  onClose?: () => void;
}) {
  const failed = state === 'failed' || state === 'interrupted';
  return createPortal(
    <aside
      className={`operation ${state}`}
      aria-label="Operation notification"
      role={failed ? 'alert' : 'status'}
    >
      {state === 'running' ? (
        <LoaderCircle className="spin" size={17} />
      ) : state === 'succeeded' ? (
        <Check size={17} />
      ) : (
        <X size={17} />
      )}
      <details>
        <summary>{title}</summary>
        <pre>{message}</pre>
      </details>
      {failed && <GetHelp />}
      {onCancel && (
        <button className="button quiet" onClick={onCancel}>
          Cancel
        </button>
      )}
      {onClose && (
        <button className="icon-button" aria-label="Close notification" onClick={onClose}>
          <X size={14} />
        </button>
      )}
    </aside>,
    document.body,
  );
}
