import { useEffect, useReducer, type ReactNode } from 'react';
import { bridges } from './bridge';

const repo = 'https://github.com/Layr-Labs/d-inference/pull/';

export interface Step {
  /** Short state name, e.g. "Scanning this Mac". */
  label: string;
  /** What to look for in this state, and which runtime data produces it. */
  note?: ReactNode;
  /** Audit PRs that changed this state. */
  prs?: number[];
  node: ReactNode;
  /** Fixed surface height, for components that use fixed positioning (dialogs, onboarding). */
  height?: number;
}

/**
 * One flow of the current app (the After tree, every audit PR applied), shown as a sequence of
 * states rendered from fixtures. Use Compare instead when showing a single fix.
 */
export function Walkthrough({
  title,
  intro,
  steps,
  log = false,
}: {
  title: string;
  intro: ReactNode;
  steps: Step[];
  /** Show what the app sent to the mocked runtime (the After bridge). */
  log?: boolean;
}) {
  return (
    <div className="sb-compare">
      <header className="sb-intro">
        <span className="sb-pr">Current app · all audit PRs</span>
        <h1>{title}</h1>
        <div className="sb-flow-intro">{intro}</div>
      </header>
      <ol className="sb-flow">
        {steps.map((step, i) => (
          <li key={step.label} className="sb-flow-step">
            <div className="sb-flow-head">
              <h2>
                <span className="sb-flow-n">{i + 1}</span> {step.label}
              </h2>
              {!!step.prs?.length && (
                <span className="sb-flow-prs">
                  Changed by{' '}
                  {step.prs.map((pr, j) => (
                    <span key={pr}>
                      {j > 0 && ', '}
                      <a href={`${repo}${pr}`} target="_blank" rel="noreferrer">
                        #{pr}
                      </a>
                    </span>
                  ))}
                </span>
              )}
            </div>
            {step.note && <div className="sb-flow-note">{step.note}</div>}
            <section className="sb-pane sb-after" aria-label={step.label}>
              <div className="sb-surface" style={step.height ? { height: step.height } : undefined}>
                <main className="page-content">{step.node}</main>
              </div>
            </section>
          </li>
        ))}
      </ol>
      {log && <FlowLog />}
    </div>
  );
}

function FlowLog() {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  useEffect(() => bridges.after.subscribe(rerender), []);
  const lines = bridges.after.log;
  return (
    <div className="sb-log" aria-label="Actions the app sent">
      <strong>Sent to the runtime ({lines.length})</strong>
      {lines.length ? (
        <ol>
          {lines.map((line, i) => (
            <li key={i}>
              <code>{line}</code>
            </li>
          ))}
        </ol>
      ) : (
        <p>Nothing yet.</p>
      )}
    </div>
  );
}
