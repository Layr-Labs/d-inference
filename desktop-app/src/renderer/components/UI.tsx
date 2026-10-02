import { ArrowUpRight, Check, LoaderCircle, Monitor, X } from 'lucide-react';
import { useEffect, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from 'react';
import { api } from '../useBackend';
import type { BackendState } from '../useBackend';
export function Button({
  children,
  variant = 'secondary',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: 'primary' | 'secondary' | 'quiet' | 'danger';
}) {
  return (
    <button {...props} className={`button ${variant} ${props.className || ''}`}>
      {children}
    </button>
  );
}
export function Status({ state, children }: { state?: string; children: ReactNode }) {
  return (
    <span className={`status ${state || ''}`}>
      <i />
      {children}
    </span>
  );
}
export function Empty({
  title,
  children,
  action,
}: {
  title: string;
  children?: ReactNode;
  action?: ReactNode;
}) {
  return (
    <div className="empty">
      <Monitor size={32} strokeWidth={1.2} />
      <h3>{title}</h3>
      <p>{children}</p>
      {action}
    </div>
  );
}
export function Header({
  title,
  description,
  action,
  level = 1,
}: {
  level?: 1 | 2;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  const Heading = level === 1 ? 'h1' : 'h2';
  return (
    <header className="page-heading">
      <div>
        <Heading>{title}</Heading>
        {description && <p>{description}</p>}
      </div>
      {action}
    </header>
  );
}
export function External({
  target,
  children,
}: {
  target: Parameters<NonNullable<typeof api>['openExternal']>[0];
  children: ReactNode;
}) {
  return (
    <button className="text-link" onClick={() => void api?.openExternal(target)}>
      {children}
      <ArrowUpRight size={15} />
    </button>
  );
}
export function Notice({ children, onClose }: { children: ReactNode; onClose?: () => void }) {
  return (
    <div className="notice" role="alert">
      {children}
      {onClose && (
        <button aria-label="Dismiss" onClick={onClose}>
          <X size={16} />
        </button>
      )}
    </div>
  );
}
export function OperationFeed({
  backend,
  inline = false,
}: {
  backend: BackendState;
  inline?: boolean;
}) {
  const [dismissed, setDismissed] = useState('');
  const operation = backend.state?.operations[0];
  if (!operation || operation.id === dismissed) return null;
  return (
    <aside
      className={`operation ${operation.state} ${inline ? 'operation-inline' : ''}`}
      aria-live="polite"
    >
      {inline && operation.state === 'running' && (
        <span
          className="operation-progress"
          role="progressbar"
          aria-label={`${operation.action} in progress`}
        />
      )}
      {operation.state === 'running' ? (
        <LoaderCircle className="spin" size={17} />
      ) : operation.state === 'succeeded' ? (
        <Check size={17} />
      ) : (
        <X size={17} />
      )}
      <details>
        <summary>
          {operation.action.charAt(0).toUpperCase() + operation.action.slice(1)} · {operation.state}
        </summary>
        <pre>{operation.message}</pre>
      </details>
      {operation.state === 'running' && operation.cancellable && (
        <Button
          variant="quiet"
          onClick={() => void backend.act({ action: 'cancel', operation: operation.id })}
        >
          Cancel
        </Button>
      )}
      {operation.state !== 'running' && (
        <button
          className="icon-button"
          aria-label="Dismiss operation"
          onClick={() => setDismissed(operation.id)}
        >
          <X size={14} />
        </button>
      )}
    </aside>
  );
}
export function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const element = ref.current!;
    element.querySelector<HTMLButtonElement>('button')?.focus();
    const keydown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        onClose();
      }
      if (event.key !== 'Tab') return;
      const controls = [
        ...element.querySelectorAll<HTMLElement>(
          'button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex="0"]',
        ),
      ];
      const first = controls[0],
        last = controls.at(-1);
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last?.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first?.focus();
      }
    };
    element.addEventListener('keydown', keydown);
    return () => {
      element.removeEventListener('keydown', keydown);
      previous?.focus();
    };
  }, [onClose]);
  return (
    <div className="modal-backdrop" onClick={onClose}>
      <section
        ref={ref}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="modal"
        onClick={(event) => event.stopPropagation()}
      >
        <header>
          <h2>{title}</h2>
          <button aria-label="Close dialog" onClick={onClose}>
            <X size={20} />
          </button>
        </header>
        {children}
      </section>
    </div>
  );
}
