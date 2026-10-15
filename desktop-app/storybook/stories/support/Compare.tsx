import { useEffect, useReducer, type ReactNode } from 'react';
import { bridges, type Version } from './bridge';

const repo = 'https://github.com/Layr-Labs/d-inference/pull/';

export function Compare({
  pr,
  title,
  wrong,
  fixed,
  before,
  after,
  stack = false,
  log = false,
  height,
  labels = {},
}: {
  pr: number;
  title: string;
  wrong: ReactNode;
  fixed: ReactNode;
  before: ReactNode;
  after: ReactNode;
  /** Put the panes above each other for wide screens such as Models or Studio. */
  stack?: boolean;
  /** Show what each version sent to the mocked runtime. */
  log?: boolean;
  /** Fixed pane height, for components that use fixed positioning (dialogs). */
  height?: number;
  /** Pane badges, when a pane isn't simply the base tree or the PR (e.g. a rule undone). */
  labels?: { before?: string; after?: string };
}) {
  return (
    <div className="sb-compare">
      <header className="sb-intro">
        <a className="sb-pr" href={`${repo}${pr}`} target="_blank" rel="noreferrer">
          PR #{pr}
        </a>
        <h1>{title}</h1>
        <div className="sb-explain">
          <section className="sb-wrong">
            <h2>What was wrong</h2>
            {wrong}
          </section>
          <section className="sb-fixed">
            <h2>What the PR changes</h2>
            {fixed}
          </section>
        </div>
      </header>
      <div className={stack ? 'sb-panes sb-stack' : 'sb-panes'}>
        <Pane version="before" label={labels.before ?? 'Before · bfa75a2c'} log={log} height={height}>
          {before}
        </Pane>
        <Pane version="after" label={labels.after ?? `After · PR #${pr}`} log={log} height={height}>
          {after}
        </Pane>
      </div>
    </div>
  );
}

function Pane({
  version,
  label,
  log,
  height,
  children,
}: {
  version: Version;
  label: string;
  log: boolean;
  height?: number;
  children: ReactNode;
}) {
  return (
    <section className={`sb-pane sb-${version}`} aria-label={label}>
      <h2 className="sb-badge">{label}</h2>
      <div className="sb-surface" style={height ? { height } : undefined}>
        <main className="page-content">{children}</main>
      </div>
      {log && <ActionLog version={version} />}
    </section>
  );
}

function ActionLog({ version }: { version: Version }) {
  const [, rerender] = useReducer((n: number) => n + 1, 0);
  useEffect(() => bridges[version].subscribe(rerender), [version]);
  const lines = bridges[version].log;
  return (
    <div className="sb-log" aria-label={`Actions the ${version} version sent`}>
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

/** A labeled observation, for behavior that is not a single static screen. */
export function Observed({ children }: { children: ReactNode }) {
  return <p className="sb-observed">{children}</p>;
}
