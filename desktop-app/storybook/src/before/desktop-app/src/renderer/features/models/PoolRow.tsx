import { Download, LoaderCircle, Pin, PinOff, Plus, Trash2 } from 'lucide-react';
import type { NativeModel, Operation } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { modelFacts } from '../../models/facts';
import { ModelGlyph } from './ModelGlyph';
import { ModelEarningsAmount } from './ModelEarnings';
import type { ModelEarnings } from './earnings';
import { poolLabels, type PoolState } from './pool';
import styles from './autopilot.module.css';
import { money } from '../../format';

function Progress({ operation }: { operation?: Operation }) {
  const fraction = operation?.progress;
  const known = fraction !== undefined;
  return (
    <span className={styles.progress}>
      <span
        role="progressbar"
        aria-label="Download progress"
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={known ? Math.round(fraction * 100) : undefined}
        data-indeterminate={!known}
      >
        <i style={known ? { width: `${fraction * 100}%` } : undefined} />
      </span>
      {known ? `${Math.round(fraction * 100)}%` : 'Downloading…'}
    </span>
  );
}

export function PoolRow({
  model,
  earnings,
  networkEarnings,
  busy,
  state,
  download,
  working,
  pinBlocked,
  onDownload,
  onJoin,
  onPin,
  onUnpin,
  onRemove,
}: {
  model: NativeModel;
  earnings: ModelEarnings;
  networkEarnings?: ReadonlyMap<string, bigint> | null;
  busy?: boolean;
  state: PoolState;
  download?: Operation;
  working?: string;
  pinBlocked?: string;
  onDownload: () => void;
  onJoin: () => void;
  onPin: () => void;
  onUnpin: () => void;
  onRemove: () => void;
}) {
  const pinned = state === 'pinned';
  const pinnable = state !== 'ineligible' && state !== 'downloading';
  return (
    <article className={`model-row ${styles.row}`} data-state={state}>
      <ModelGlyph name={model.display_name} />
      <div className="model-description">
        <div>
          <h3>{model.display_name}</h3>
          <span className={styles.badge} data-state={state}>
            {state === 'pinned' && <Pin size={11} />}
            {pinned
              ? model.loaded
                ? 'In memory · kept'
                : 'Kept · waiting to load'
              : poolLabels[state]}
          </span>
        </div>
        <small className={state === 'ineligible' ? 'warning-text' : 'muted'}>
          {modelFacts(model)}
        </small>
        {model.description && (
          <details className={styles.description}>
            <summary>Model details</summary>
            <p>{model.description}</p>
          </details>
        )}
      </div>
      {networkEarnings !== undefined ? (
        <span className="model-earned" title="Network inference earnings · past 7 days">
          {networkEarnings ? money(String(networkEarnings.get(model.id) ?? 0n)) : '—'}
        </span>
      ) : (
        <ModelEarningsAmount model={model.id} earnings={earnings} />
      )}
      <fieldset className={`model-actions ${styles.actions}`} disabled={busy}>
        {working && state !== 'downloading' ? (
          <span className={styles.working} role="status">
            <LoaderCircle className="spin" size={14} /> {working}
          </span>
        ) : state === 'downloading' ? (
          <Progress operation={download} />
        ) : (
          <>
            {state === 'available' && (
              <Button onClick={onDownload} title="Downloads the model and adds it to the pool">
                <Download size={15} /> Download
              </Button>
            )}
            {state === 'outside' && (
              <Button onClick={onJoin}>
                <Plus size={15} /> Add to pool
              </Button>
            )}
            {pinnable && state === 'available' && (
              <Button
                disabled={!!pinBlocked}
                onClick={onPin}
                title={pinBlocked}
                aria-label={`Download & keep ${model.display_name} in memory`}
              >
                <Pin size={14} /> Download & keep in memory
              </Button>
            )}
            {pinnable && state !== 'available' && (
              <button
                className={styles.pin}
                aria-pressed={pinned}
                aria-label={`${pinned ? 'Stop keeping' : 'Keep'} ${model.display_name} in memory`}
                title={
                  pinBlocked ??
                  (pinned
                    ? 'Let Autopilot unload it'
                    : 'Protect from unloading while Autopilot is active')
                }
                disabled={!pinned && !!pinBlocked}
                onClick={pinned ? onUnpin : onPin}
              >
                {pinned ? <PinOff size={14} /> : <Pin size={14} />}
                Keep in memory
              </button>
            )}
            {model.downloaded && (
              <button
                className="icon-button"
                aria-label={`Remove ${model.display_name}`}
                title={
                  pinned
                    ? 'Unpin it first'
                    : model.loaded || model.serving
                      ? 'Stop serving this model before removing it'
                      : 'Remove from this Mac'
                }
                disabled={pinned || model.loaded || model.serving}
                onClick={onRemove}
              >
                <Trash2 size={16} />
              </button>
            )}
          </>
        )}
      </fieldset>
    </article>
  );
}
