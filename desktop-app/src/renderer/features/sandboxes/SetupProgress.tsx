import { useState } from 'react';
import { ArrowUpRight, Check, Circle, Copy, LoaderCircle, X } from 'lucide-react';
import type { Operation } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';
import { Button } from '../../components/UI';
import {
  outputLines,
  pendingApproval,
  setupOutcome,
  setupSteps,
  type SetupStep,
  type StepState,
} from './setup';
import styles from './sandboxes.module.css';

const stateWords: Record<StepState, string> = {
  done: 'Done',
  active: 'In progress',
  failed: 'Failed',
  stopped: 'Stopped',
  pending: 'Not started',
};

// A `sandbox_setup` operation: the installer's stages, the one browser approval, the waitlist,
// and once it ends without success what the installer's exit status means.
export function SetupProgress({
  operation,
  backend,
  onDismiss,
}: {
  operation: Operation;
  backend: BackendState;
  onDismiss?: () => void;
}) {
  const progress = operation.sandbox_setup ?? {};
  const running = operation.state === 'running';
  const steps = setupSteps(operation);
  const outcome = setupOutcome(operation);
  const approval = pendingApproval(operation);
  const lines = outputLines(operation);
  return (
    <section
      className={styles.setup}
      aria-label="Darkbloom Sandbox setup"
      aria-busy={running}
      data-state={operation.state}
    >
      <header className={styles.setupHead}>
        <h2>{running ? 'Setting up Darkbloom Sandbox' : outcome?.title}</h2>
        {running && operation.cancellable && (
          <Button
            variant="quiet"
            onClick={() => void backend.act({ action: 'cancel', operation: operation.id })}
          >
            Cancel
          </Button>
        )}
        {!running && onDismiss && (
          <button
            type="button"
            className="icon-button"
            aria-label="Dismiss setup result"
            onClick={onDismiss}
          >
            <X size={15} />
          </button>
        )}
      </header>
      {!running && outcome?.detail && <p className={styles.outcome}>{outcome.detail}</p>}
      {(steps.length > 0 || approval || (running && progress.waitlisted)) && (
        <div className={styles.setupBody}>
          {steps.length > 0 && <Steps steps={steps} />}
          {(approval || (running && progress.waitlisted)) && (
            <div className={styles.setupAside}>
              {approval && <Approval {...approval} background={!!progress.background} />}
              {running && progress.waitlisted && <Waitlisted background={!!progress.background} />}
            </div>
          )}
        </div>
      )}
      {lines.length > 0 && (
        <details className={styles.output}>
          <summary>Details</summary>
          <pre tabIndex={0}>{lines.join('\n')}</pre>
        </details>
      )}
    </section>
  );
}

function Steps({ steps }: { steps: SetupStep[] }) {
  return (
    <ol className={styles.steps} aria-label="Setup steps">
      {steps.map((step) => (
        <li
          key={step.id}
          data-state={step.state}
          aria-current={step.state === 'active' ? 'step' : undefined}
        >
          <StepMark state={step.state} />
          <span>
            <span className={styles.srOnly}>{stateWords[step.state]}: </span>
            {step.title}
          </span>
          {step.progress !== undefined && (
            <span className={styles.bar} aria-hidden>
              <i style={{ width: `${step.progress * 100}%` }} />
            </span>
          )}
          {step.detail && <small>{step.detail}</small>}
        </li>
      ))}
    </ol>
  );
}

function StepMark({ state }: { state: StepState }) {
  if (state === 'done') return <Check size={14} aria-hidden />;
  if (state === 'active') return <LoaderCircle className="spin" size={14} aria-hidden />;
  if (state === 'failed' || state === 'stopped') return <X size={14} aria-hidden />;
  return <Circle size={8} aria-hidden />;
}

// The one approval: the page with the code filled in, opened only from the button.
function Approval({
  code,
  url,
  codeFilled,
  background,
}: {
  code: string;
  url: string;
  codeFilled: boolean;
  background: boolean;
}) {
  const [copied, setCopied] = useState('');
  const [failed, setFailed] = useState(false);
  const copy = async (text: string) => {
    try {
      await api?.copy(text);
      setCopied(text);
    } catch {
      setCopied('');
    }
  };
  const open = async () => {
    try {
      await api?.openApproval(url);
      setFailed(false);
    } catch {
      setFailed(true);
    }
  };
  return (
    <section className={styles.approval} aria-label="Approve this Mac">
      <strong>Approve this Mac</strong>
      <small>
        Sign in with the Darkbloom account that should get this Mac’s earnings
        {codeFilled ? ', check the code' : ', enter the code'}, then press Approve.
      </small>
      {code && (
        <div className={styles.code}>
          <strong aria-label={`Approval code ${code}`}>{code}</strong>
          <Button onClick={() => void copy(code)}>
            {copied === code ? <Check size={15} /> : <Copy size={15} />}
            {copied === code ? 'Copied' : 'Copy code'}
          </Button>
        </div>
      )}
      <div className={styles.approvalActions}>
        <Button variant="primary" onClick={() => void open()}>
          Open approval page <ArrowUpRight size={15} />
        </Button>
        <button type="button" className="text-link" onClick={() => void copy(url)}>
          {copied === url ? 'Link copied' : 'Copy link'}
        </button>
      </div>
      {failed && (
        <p className={styles.error} role="alert">
          Couldn’t open the page. Copy the link and open it in a browser.
        </p>
      )}
      {background && (
        <p className={styles.aside}>
          You can close the app: this Mac enrolls by itself once you approve it, also after a
          restart.
        </p>
      )}
    </section>
  );
}

function Waitlisted({ background }: { background: boolean }) {
  return (
    <section className={styles.waitlisted} aria-label="On the waitlist">
      <strong>Your account is on the waitlist</strong>
      <small>Darkbloom reviews new Mac owners before their first Mac joins.</small>
      <p className={styles.aside}>
        {background
          ? 'You can close the app: this Mac keeps waiting, also across restarts, and enrolls by itself once your account is approved.'
          : 'Leave setup running; this Mac enrolls once your account is approved.'}
      </p>
    </section>
  );
}
