import { LoaderCircle, LogOut, Monitor, RotateCw, Square, Play, ArrowRight } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import type { Action } from '../../../shared/contracts';
import type { ClusterStatus } from '../../../shared/cluster';
import type { BackendState } from '../../useBackend';
import { Button, Modal } from '../../components/UI';
import { PairGlyph, type PairMood } from './PairGlyph';
import { CopyCommand, Rich } from './Rich';
import {
  modelName,
  notOffered,
  pairActions,
  servingWay,
  servingWords,
  shares,
  stateTone,
  stateWords,
} from './status';
import type { ClusterSessionControl } from './useClusterSession';
import styles from './cluster.module.css';

const moods: Record<ClusterStatus['state'], PairMood> = {
  serving: 'serving',
  loading: 'starting',
  not_serving: 'failed',
  stopped: 'stopped',
  other_mac_away: 'away',
  not_paired: 'invite',
  unknown: 'stopped',
  pairing_unreadable: 'failed',
};

function MacCard({
  label,
  name,
  role,
  answers,
}: {
  label: string;
  name: string | null;
  role: 'Leads' | 'Follows' | null;
  answers?: boolean | null;
}) {
  return (
    <div className={styles.macCard} data-away={answers === false || undefined}>
      <span className={styles.macLabel}>
        <Monitor size={13} strokeWidth={1.6} aria-hidden="true" />
        {label}
      </span>
      <strong>{name ?? '—'}</strong>
      <span className={styles.macFacts}>
        {role && <span className={styles.tagRole}>{role}</span>}
        {answers === true && (
          <span className={styles.answers} data-answers="true">
            <i /> Answers
          </span>
        )}
        {answers === false && (
          <span className={styles.answers} data-answers="false">
            <i /> Not answering
          </span>
        )}
      </span>
    </div>
  );
}

// Each Mac's share of the model, as a bar: "M3 Ultra 50% / M5 Max 50%".
function Split({ split }: { split: string }) {
  const parts = shares(split);
  if (!parts) return <p className={styles.splitText}>{split}</p>;
  return (
    <div className={styles.split}>
      <div className={styles.splitBar} aria-hidden="true">
        {parts.map((part, index) => (
          <i key={index} style={{ flexGrow: Math.max(part.weight, 0.04) }} data-part={index % 2} />
        ))}
      </div>
      <ul className={styles.splitLegend} aria-label="Split">
        {parts.map((part, index) => (
          <li key={index}>
            <i data-part={index % 2} aria-hidden="true" />
            {part.name} <b>{part.amount}</b>
          </li>
        ))}
      </ul>
    </div>
  );
}

function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <dt>{label}</dt>
      <dd>{children}</dd>
    </div>
  );
}

type Confirm = 'alone' | 'leave' | null;

// A paired Mac: both Macs, the model and how it serves, the state with the runtime's own reason
// and next step, and what can be done from here. Start, Stop and Restart serving act on the pair;
// the model is chosen on the Mac that leads.
export function PairStatus({
  backend,
  status,
  refreshing,
  refresh,
  session,
}: {
  backend: BackendState;
  status: ClusterStatus;
  refreshing: boolean;
  refresh: () => Promise<void>;
  // Null when this runtime has no in-app setup: changes are made in Terminal.
  session: ClusterSessionControl | null;
}) {
  const [pending, setPending] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<Confirm>(null);
  const actions = pairActions(status);
  const way = servingWay(status);
  const name = modelName(status);
  const member = status.role === 'member';
  const unreadable = status.state === 'pairing_unreadable';
  const busy = backend.busy || pending !== null || !!session?.pending;
  const run = async (label: string, action: Action) => {
    setPending(label);
    try {
      await backend.act(action, true);
    } finally {
      await refresh();
      setPending(null);
    }
  };
  const label = (text: string) =>
    pending === text ? (
      <>
        <LoaderCircle className="spin" size={15} aria-hidden="true" /> {text}
      </>
    ) : (
      text
    );
  const primaryStart = actions.start;
  return (
    <>
      <section className={styles.pair} aria-label="Pair" aria-busy={refreshing || undefined}>
        <div className={styles.macs}>
          <MacCard
            label="This Mac"
            name={status.this_mac}
            role={status.role === 'leader' ? 'Leads' : member ? 'Follows' : null}
          />
          <PairGlyph mood={moods[status.state] ?? 'stopped'} className={styles.pairGlyph} />
          <MacCard
            label="The other Mac"
            name={status.other_mac?.name ?? null}
            role={status.role === 'leader' ? 'Follows' : member ? 'Leads' : null}
            answers={status.other_mac?.answers}
          />
        </div>

        <div className={styles.pairBody}>
          <div className={styles.stateRow}>
            <span className={styles.statePill} data-tone={stateTone[status.state] ?? 'idle'}>
              {status.state === 'loading' ? (
                <LoaderCircle className="spin" size={12} aria-hidden="true" />
              ) : (
                <i aria-hidden="true" />
              )}
              {stateWords[status.state] ?? 'Unknown'}
            </span>
            {name && (
              <h2 className={styles.modelName}>
                {name}
                {status.mode && <span className={styles.tagMode}>{status.mode}</span>}
              </h2>
            )}
          </div>
          {status.split && <Split split={status.split} />}
          {(status.reason || status.next) && (
            <div className={styles.why} data-tone={stateTone[status.state] ?? 'idle'}>
              {status.reason && (
                <p className={styles.reason}>
                  <Rich text={status.reason} />
                </p>
              )}
              {status.next && (
                <p className={styles.next}>
                  <Rich text={status.next} />
                </p>
              )}
            </div>
          )}

          <div className={styles.actions}>
            {actions.start && (
              <Button
                variant={primaryStart ? 'primary' : 'secondary'}
                disabled={busy}
                onClick={() => void run('Start serving', { action: 'start', models: [] })}
              >
                {pending === 'Start serving' ? null : <Play size={14} aria-hidden="true" />}
                {label('Start serving')}
              </Button>
            )}
            {actions.stop && (
              <Button disabled={busy} onClick={() => void run('Stop serving', { action: 'stop' })}>
                {pending === 'Stop serving' ? null : <Square size={13} aria-hidden="true" />}
                {label('Stop serving')}
              </Button>
            )}
            {actions.restart && (
              <Button
                disabled={busy}
                onClick={() => void run('Restart serving', { action: 'restart' })}
              >
                {pending === 'Restart serving' ? null : <RotateCw size={14} aria-hidden="true" />}
                {label('Restart serving')}
              </Button>
            )}
            {actions.change && session && (
              <Button disabled={busy} onClick={() => void session.start('setup')}>
                {unreadable ? 'Check the pairing' : 'Change model or how it serves'}
                <ArrowRight size={14} aria-hidden="true" />
              </Button>
            )}
          </div>
          {actions.change && !session && (
            <p className={styles.terminalHint}>
              {unreadable ? 'Check the pairing in Terminal:' : 'Change the model in Terminal:'}{' '}
              <CopyCommand command="darkbloom cluster" />
            </p>
          )}
          {member && !unreadable && (
            <p className={styles.terminalHint}>The other Mac leads: choose the model there.</p>
          )}
          {session?.error && (
            <p className={styles.heroError} role="alert">
              {session.error}
            </p>
          )}
        </div>
      </section>

      <dl className={styles.pairFacts}>
        {way && (
          <Fact label="Serves">
            {servingWords[way]}
            {notOffered(status) && <span className={styles.tagWarning}>not offered</span>}
          </Fact>
        )}
        {status.service && (
          <Fact label="Cluster service">
            {status.service.running ? 'Running' : 'Not running'}
            {' · '}
            {status.service.starts_at_login ? 'Starts at login' : 'Doesn’t start at login'}
          </Fact>
        )}
      </dl>

      {status.lines.length > 0 && (
        <details className={styles.lines}>
          <summary>Details</summary>
          <ul>
            {status.lines.map((line, index) => (
              <li key={index}>
                <Rich text={line.trim()} />
              </li>
            ))}
          </ul>
        </details>
      )}

      {(actions.alone || actions.leave) && (
        <section className={styles.more} aria-label="This Mac">
          {actions.alone && (
            <Button variant="quiet" disabled={busy} onClick={() => setConfirm('alone')}>
              {pending === 'Serve this Mac alone' ? null : <Monitor size={14} aria-hidden="true" />}
              {label('Serve this Mac alone')}
            </Button>
          )}
          {actions.leave && (
            <Button variant="danger" disabled={busy} onClick={() => setConfirm('leave')}>
              {pending === 'Leave the pair' ? null : <LogOut size={14} aria-hidden="true" />}
              {label('Leave the pair')}
            </Button>
          )}
        </section>
      )}

      {confirm === 'alone' && (
        <Modal title="Serve this Mac alone?" onClose={() => setConfirm(null)}>
          <p>
            {status.state === 'stopped' ? 'The pair stays stopped.' : 'The pair stops serving.'}{' '}
            <Rich text="`darkbloom start` starts the pair again." />
          </p>
          <div className="dialog-actions">
            <Button onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="primary"
              onClick={() => {
                setConfirm(null);
                void run('Serve this Mac alone', { action: 'start', models: [], solo: true });
              }}
            >
              Serve this Mac alone
            </Button>
          </div>
        </Modal>
      )}
      {confirm === 'leave' && (
        <Modal title="Leave the pair?" onClose={() => setConfirm(null)}>
          <p>
            Leaving stops the pair (on both Macs while the other Mac answers) and this Mac’s cluster
            service, and forgets this Mac’s pairing. The other Mac keeps its own pairing until it
            leaves too.
          </p>
          <div className="dialog-actions">
            <Button onClick={() => setConfirm(null)}>Cancel</Button>
            <Button
              variant="danger"
              onClick={() => {
                setConfirm(null);
                void run('Leave the pair', { action: 'cluster_leave' });
              }}
            >
              Leave the pair
            </Button>
          </div>
        </Modal>
      )}
    </>
  );
}
