import { useEffect, useRef, useState } from 'react';
import { Check, Download, Sparkles } from 'lucide-react';
import type { NativeModel, Snapshot } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { gigabytes } from '../../models/facts';
import { money } from '../../format';
import type { AutopilotAction } from '../../../shared/autopilot';
import { recommendedStart } from './recommendations';
import type { ModelActions } from './useModelActions';
import styles from './recommendations.module.css';

export function RecommendedModels({
  snapshot,
  models,
  earnings,
  actions,
  setup,
  busy,
  onStart,
}: {
  snapshot: Snapshot;
  models: NativeModel[];
  earnings: ReadonlyMap<string, bigint> | null;
  actions?: ModelActions;
  setup: boolean;
  busy: boolean;
  onStart?: (action: AutopilotAction) => void;
}) {
  const [selection, setSelection] = useState<string[]>(models.map((model) => model.id));
  const edited = useRef(false);
  const signature = models.map((model) => model.id).join('|');
  useEffect(() => {
    if (!edited.current) setSelection(models.map((model) => model.id));
  }, [signature]);
  const chosen = models.filter((model) => selection.includes(model.id));
  const missing = chosen.filter((model) => !model.downloaded);
  if (!models.length)
    return setup ? (
      <div className={styles.empty}>
        <Sparkles size={16} />
        <span>
          {earnings
            ? 'No earning recommendations yet. Choose a model below.'
            : 'Network recommendations are unavailable. Browse models to get started.'}
        </span>
      </div>
    ) : null;
  return (
    <section className={styles.section} aria-label="Recommended for your Mac">
      <header>
        <div>
          <h3>Recommended for your Mac</h3>
          <small>Top earning compatible models · network · 7 days</small>
        </div>
        {setup && (
          <Button
            variant="primary"
            disabled={busy || !chosen.length}
            onClick={() =>
              onStart
                ? onStart(recommendedStart(snapshot, chosen))
                : void actions?.policy(
                    recommendedStart(snapshot, chosen),
                    missing.length ? 'Downloading…' : 'Starting…',
                  )
            }
          >
            {missing.length ? 'Download & start Autopilot' : 'Start Autopilot'}
          </Button>
        )}
      </header>
      <div className={styles.grid}>
        {models.map((model) => (
          <article key={model.id}>
            {setup && (
              <input
                type="checkbox"
                checked={selection.includes(model.id)}
                aria-label={`Choose ${model.display_name}`}
                disabled={busy}
                onChange={() => {
                  edited.current = true;
                  setSelection((current) =>
                    current.includes(model.id)
                      ? current.filter((id) => id !== model.id)
                      : [...current, model.id],
                  );
                }}
              />
            )}
            <div>
              <strong>{model.display_name}</strong>
              <span>{money(String(earnings?.get(model.id) ?? 0n))} network earnings</span>
              <small>
                {model.downloaded ? 'Ready on this Mac' : `${gigabytes(model.size_gb)} download`}
              </small>
            </div>
            {!setup && !model.downloaded && (
              <Button
                disabled={busy}
                onClick={() => void actions?.join(model)}
                aria-label={`Download recommended ${model.display_name}`}
              >
                <Download size={14} />
              </Button>
            )}
            {model.downloaded && <Check size={15} className={styles.ready} />}
          </article>
        ))}
      </div>
      {setup && (
        <footer>
          {missing.length
            ? `${missing.length} downloads · ${gigabytes(missing.reduce((total, model) => total + model.size_gb, 0))} total`
            : 'No downloads needed'}
        </footer>
      )}
    </section>
  );
}
