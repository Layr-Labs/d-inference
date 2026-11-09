import { Check, ChevronRight, LoaderCircle, SquareTerminal, X } from 'lucide-react';
import { useEffect, useMemo, useRef, useState, type ReactElement } from 'react';
import type { ClusterSession } from '../../../shared/cluster';
import { Button, Modal, Notice } from '../../components/UI';
import { PairGlyph } from './PairGlyph';
import { KeyButtons, PairingCode, QuestionCard } from './Question';
import { CopyCommand, Rich, Said } from './Rich';
import {
  pairingInProgress,
  transcript,
  type Block,
  type Line,
  type Live,
  type Step,
} from './transcript';
import type { ClusterSessionControl } from './useClusterSession';
import styles from './cluster.module.css';

function Mark({ tone }: { tone: Line['tone'] }) {
  if (tone === 'done')
    return (
      <span className={styles.mark} data-tone="done" role="img" aria-label="Done">
        <Check size={13} strokeWidth={2.2} />
      </span>
    );
  if (tone === 'failed')
    return (
      <span className={styles.mark} data-tone="failed" role="img" aria-label="Failed">
        <X size={13} strokeWidth={2.2} />
      </span>
    );
  return null;
}

function LineView({ line }: { line: Line }) {
  if (line.code)
    return (
      <div className={styles.codeLine}>
        <PairingCode code={line.code} />
        {line.text && (
          <p>
            <Said text={line.text} stressed={line.stressed} />
          </p>
        )}
      </div>
    );
  if (line.command)
    return (
      <div className={styles.instruction}>
        <SquareTerminal size={16} strokeWidth={1.6} aria-hidden="true" />
        <p>
          <Said text={line.text} stressed={line.stressed} />
        </p>
        <CopyCommand command={line.command} bare />
      </div>
    );
  return (
    <p className={styles.line} data-tone={line.tone} data-indent={line.indent || undefined}>
      <Mark tone={line.tone} />
      <span>
        <Said text={line.text} stressed={line.stressed} />
      </span>
    </p>
  );
}

export function Outcome({ block }: { block: Extract<Block, { kind: 'result' }> }) {
  return (
    <div className={styles.outcome} data-ok={block.ok} role="status">
      <span className={styles.outcomeMark} role="img" aria-label={block.ok ? 'Done' : 'Failed'}>
        {block.ok ? <Check size={18} strokeWidth={2.2} /> : <X size={18} strokeWidth={2.2} />}
      </span>
      <div>
        <strong>
          <Rich text={block.title} />
        </strong>
        {block.lines.map((line, index) => (
          <p key={index}>
            <Rich text={line} />
          </p>
        ))}
      </div>
    </div>
  );
}

// A step that needs Terminal: the app can't answer it (sudo where macOS shows no window).
function NeedsTerminal({ block }: { block: Extract<Block, { kind: 'terminal' }> }) {
  return (
    <div className={styles.terminal} role="alert">
      <SquareTerminal size={16} strokeWidth={1.6} aria-hidden="true" />
      <p>
        <Rich text={block.text} />
      </p>
      {block.command && <CopyCommand command={block.command} bare />}
    </div>
  );
}

// Consecutive "Label:   value" lines (the pair's card) read as one table.
function Blocks({ blocks }: { blocks: Block[] }) {
  const out: ReactElement[] = [];
  let facts: Line[] = [];
  const flush = () => {
    if (!facts.length) return;
    out.push(
      <dl key={`facts-${facts[0].key}`} className={styles.facts}>
        {facts.map((line) => (
          <div key={line.key}>
            <dt>{line.fact!.command ? <code>{line.fact!.label}</code> : line.fact!.label}</dt>
            <dd>
              <Rich text={line.fact!.value} />
            </dd>
          </div>
        ))}
      </dl>,
    );
    facts = [];
  };
  for (const block of blocks) {
    if (block.kind === 'line' && block.line.fact) {
      facts.push(block.line);
      continue;
    }
    flush();
    if (block.kind === 'line') out.push(<LineView key={block.line.key} line={block.line} />);
    else if (block.kind === 'result') out.push(<Outcome key={block.key} block={block} />);
    else out.push(<NeedsTerminal key={block.key} block={block} />);
  }
  flush();
  return <>{out}</>;
}

function Bar({ percent, label }: { percent: number; label: string }) {
  return (
    <span
      className={styles.bar}
      role="progressbar"
      aria-label={label}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(percent)}
    >
      <i style={{ width: `${percent}%` }} />
    </span>
  );
}

// Work still running: one row per Mac, each with its own spinner; a copy's or download's bar.
function LiveView({ live }: { live: Live }) {
  if (live.kind === 'progress')
    return (
      <div className={styles.progress}>
        <span className={styles.progressLabel}>
          <LoaderCircle className="spin" size={14} aria-hidden="true" />
          <Rich text={live.label} />
        </span>
        {live.percent !== undefined && <Bar percent={live.percent} label={live.label} />}
        {live.figures.length > 0 && (
          <span className={styles.figures}>{live.figures.join(' · ')}</span>
        )}
      </div>
    );
  return (
    <ul className={styles.live} aria-live="polite">
      {live.rows.map((row, index) => (
        <li key={index}>
          <LoaderCircle className="spin" size={14} aria-hidden="true" />
          <span>
            <Rich text={row.text} />
          </span>
          {row.percent !== undefined && <Bar percent={row.percent} label={row.text} />}
        </li>
      ))}
    </ul>
  );
}

// A step's dot: done, failed, or the current one; its state is said for screen readers too.
function StepDot({ state }: { state: 'done' | 'failed' | 'current' }) {
  return (
    <>
      <span className={styles.stepDot} data-state={state} aria-hidden="true">
        {state === 'done' && <Check size={11} strokeWidth={2.4} />}
        {state === 'failed' && <X size={11} strokeWidth={2.4} />}
      </span>
      {state !== 'current' && (
        <span className={styles.srOnly}>{state === 'failed' ? 'Failed: ' : 'Done: '}</span>
      )}
    </>
  );
}

const stepFailed = (step: Step) =>
  step.blocks.some(
    (block) =>
      (block.kind === 'result' && !block.ok) ||
      (block.kind === 'line' && block.line.tone === 'failed'),
  );

// True once `key` has stayed the same for `ms`.
function useSettled(key: string, ms: number) {
  const [settled, setSettled] = useState<string | null>(null);
  useEffect(() => {
    const timer = setTimeout(() => setSettled(key), ms);
    return () => clearTimeout(timer);
  }, [key, ms]);
  return settled === key;
}

// The guided setup: the CLI's own screen, step by step, with its questions as the app's own
// controls. Finished steps fold to their title, as the terminal folds them.
export function Wizard({
  session,
  control,
  onRestart,
}: {
  session: ClusterSession;
  control: ClusterSessionControl;
  onRestart: () => void;
}) {
  const view = useMemo(() => transcript(session), [session]);
  const root = useRef<HTMLElement>(null);
  const foot = useRef<HTMLElement>(null);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const [confirm, setConfirm] = useState(false);
  const running = session.state === 'running';
  const busy = control.pending !== null;
  const current = view.steps.at(-1);
  const question = running ? session.question : null;
  const stepCount = view.steps.length;
  // The setup's title takes focus when it replaces the page and nothing else has it, so a screen
  // reader starts there; a question takes it from there.
  useEffect(() => {
    const active = document.activeElement;
    if (!active || active === document.body) titleRef.current?.focus();
  }, []);
  // "Working…" only when nothing has changed for a moment: lines often come in quick bursts.
  const idle = useSettled(`${session.events.length}:${session.question?.id ?? ''}`, 1200);
  // The outcome's Done takes focus when the session ends with nothing else focused.
  useEffect(() => {
    if (running) return;
    const active = document.activeElement;
    if (!active || active === document.body)
      foot.current?.querySelector<HTMLButtonElement>('button:last-child')?.focus();
  }, [running]);
  const cancel = () => {
    if (pairingInProgress(view)) setConfirm(true);
    else void control.cancel();
  };
  const title = view.title || 'Clusters';
  const mood = running
    ? 'starting'
    : session.state === 'succeeded' && view.outcome?.ok !== false
      ? 'serving'
      : session.state === 'cancelled'
        ? 'stopped'
        : 'failed';
  return (
    <section ref={root} className={styles.wizard} aria-label="Cluster setup">
      <header className={styles.wizardHead}>
        <PairGlyph mood={mood} className={styles.wizardGlyph} />
        <div className={styles.wizardTitle}>
          <h1 ref={titleRef} tabIndex={-1}>
            {title}
          </h1>
          {view.subtitle && <p>{view.subtitle}</p>}
        </div>
        {view.meter && running && (
          <div
            className={styles.meter}
            role="img"
            aria-label={`Step ${view.meter.index} of ${view.meter.total}`}
          >
            {Array.from({ length: view.meter.total }, (_, index) => (
              <i key={index} data-on={index < view.meter!.index || undefined} />
            ))}
          </div>
        )}
        {running && (
          <Button variant="quiet" disabled={busy} onClick={cancel}>
            Cancel
          </Button>
        )}
      </header>

      {view.intro.length > 0 && (
        <div className={styles.intro}>
          <Blocks blocks={view.intro} />
        </div>
      )}

      <ol className={styles.timeline}>
        {view.steps.map((step, index) => {
          const last = index === stepCount - 1;
          const failed = stepFailed(step);
          if (!last)
            return (
              <li key={step.key} className={styles.step} data-state={failed ? 'failed' : 'done'}>
                <details className={styles.folded}>
                  <summary>
                    <StepDot state={failed ? 'failed' : 'done'} />
                    <span>{step.title}</span>
                    <ChevronRight size={14} aria-hidden="true" className={styles.chevron} />
                  </summary>
                  <div className={styles.stepBody}>
                    <Blocks blocks={step.blocks} />
                  </div>
                </details>
              </li>
            );
          return (
            <li
              key={step.key}
              className={styles.step}
              data-state={running ? 'current' : failed ? 'failed' : 'done'}
              aria-current={running ? 'step' : undefined}
            >
              <h2 className={styles.stepTitle}>
                <StepDot state={running ? 'current' : failed ? 'failed' : 'done'} />
                {step.title}
              </h2>
              <div className={styles.stepBody}>
                <Blocks blocks={step.blocks} />
                {view.live && <LiveView live={view.live} />}
                {question?.type === 'key' && !view.prompt && (
                  <KeyButtons
                    question={question}
                    disabled={busy}
                    onKey={(key) => void control.answer({ question: question.id, key })}
                  />
                )}
                {question && (question.type === 'choose' || view.prompt) && (
                  <QuestionCard
                    question={question}
                    prompt={view.prompt}
                    fallback={step.title}
                    disabled={busy}
                    within={root}
                    onAnswer={(answer) => void control.answer(answer)}
                  />
                )}
              </div>
            </li>
          );
        })}
      </ol>

      {!current && running && view.live && <LiveView live={view.live} />}
      {!current && question && (
        <QuestionCard
          question={question}
          prompt={view.prompt}
          fallback={title}
          disabled={busy}
          within={root}
          onAnswer={(answer) => void control.answer(answer)}
        />
      )}
      {running && idle && !view.live && !question && (
        <p className={styles.waiting} role="status">
          <LoaderCircle className="spin" size={14} aria-hidden="true" /> Working…
        </p>
      )}

      {session.error && (
        <div className={styles.outcome} data-ok={false} role="alert">
          <span className={styles.outcomeMark} role="img" aria-label="Failed">
            <X size={18} strokeWidth={2.2} />
          </span>
          <div>
            <strong>
              <Rich text={session.error} />
            </strong>
          </div>
        </div>
      )}
      {control.error && <Notice onClose={control.clearError}>{control.error}</Notice>}

      {!running && (
        <footer ref={foot} className={styles.wizardFoot}>
          {session.state === 'failed' && <Button onClick={onRestart}>Run again</Button>}
          <Button variant="primary" onClick={control.dismiss}>
            Done
          </Button>
        </footer>
      )}

      {confirm && (
        <Modal title="Stop pairing?" onClose={() => setConfirm(false)}>
          <p>The Macs won’t be paired.</p>
          <div className="dialog-actions">
            <Button onClick={() => setConfirm(false)}>Keep pairing</Button>
            <Button
              variant="danger"
              onClick={() => {
                setConfirm(false);
                void control.cancel();
              }}
            >
              Stop pairing
            </Button>
          </div>
        </Modal>
      )}
    </section>
  );
}
