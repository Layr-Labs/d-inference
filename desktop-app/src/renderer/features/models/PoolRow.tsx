import { Download, LoaderCircle, Pin, PinOff, Plus, Trash2 } from 'lucide-react';
import type { NativeModel, Operation } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { modelFacts } from '../../models/facts';
import { ModelGlyph } from './ModelGlyph';
import { ModelEarningsAmount } from './ModelEarnings';
import type { ModelEarnings } from './earnings';
import { poolLabels, type PoolState } from './pool';
import styles from './autopilot.module.css';

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
            {poolLabels[state]}
          </span>
        </div>
        <p>{model.description || model.id}</p>
        <small className={state === 'ineligible' ? 'warning-text' : 'muted'}>
          {modelFacts(model)}
        </small>
        {pinned && <small className={styles.hint}>Unpin it to remove it from this Mac.</small>}
      </div>
      <ModelEarningsAmount model={model.id} earnings={earnings} />
      <div className="model-actions">
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
            {pinnable && (
              <button
                className={styles.pin}
                aria-pressed={pinned}
                aria-label={`${pinned ? 'Unpin' : 'Pin'} ${model.display_name}`}
                title={pinBlocked ?? (pinned ? 'Let Autopilot unload it' : 'Keep it always loaded')}
                disabled={!pinned && !!pinBlocked}
                onClick={pinned ? onUnpin : onPin}
              >
                {pinned ? <PinOff size={14} /> : <Pin size={14} />}
                {pinned ? 'Unpin' : 'Pin'}
              </button>
            )}
            {model.downloaded && (
              <button
                className="icon-button"
                aria-label={`Remove ${model.display_name}`}
                title={pinned ? 'Unpin it first' : 'Remove from this Mac'}
                disabled={pinned}
                onClick={onRemove}
              >
                <Trash2 size={16} />
              </button>
            )}
          </>
        )}
      </div>
    </article>
  );
}
