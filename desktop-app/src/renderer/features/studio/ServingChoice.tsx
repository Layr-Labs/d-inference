import { useEffect, useId, useState } from 'react';
import { ArrowUpRight, Play } from 'lucide-react';
import type { Route } from '../../../shared/contracts';
import type { LocalServing, ServingMode } from '../../../shared/localServing';
import type { BackendState } from '../../useBackend';
import { Button } from '../../components/UI';
import { modelName } from '../../models/facts';
import { ChoiceCard } from './ChoiceCard';
import { names, servableModels, servingChoices, servingDetail, servingNow } from './words';
import styles from './studio.module.css';

// Each way to serve is one `start` flag; the start saves it as `[local] mode` once it goes ahead,
// and the background service, restart and update serve it from then on.
const startFlag: Record<ServingMode, { local?: true; network?: true; endpoint?: true }> = {
  local: { local: true },
  network: { network: true },
  both: { endpoint: true },
};

// The start question as three answers, the saved one marked. Nothing changes until Apply, which
// restarts serving the chosen way with the models serving now.
export function ServingChoice({
  backend,
  local,
  navigate,
}: {
  backend: BackendState;
  local: LocalServing;
  navigate?: (route: Route) => void;
}) {
  const state = backend.state!;
  const heading = useId();
  const group = useId();
  const saved = local.mode;
  // The question's own default when nothing is saved yet.
  const [draft, setDraft] = useState<ServingMode>(saved ?? 'both');
  useEffect(() => setDraft(saved ?? 'both'), [saved]);
  const keep = servingNow(state, draft);
  const choices = servableModels(state, draft);
  const [chosen, setChosen] = useState('');
  const pick = choices.some((model) => model.id === chosen) ? chosen : (choices[0]?.id ?? '');
  const models = keep.length ? keep.map((model) => model.id) : pick ? [pick] : [];
  const changed = draft !== saved;
  // On a paired Mac a start starts the pair, which serves its own way.
  const paired = !!state.pair;
  const verb = state.state === 'stopped' ? 'starts' : 'restarts';
  return (
    <section className="settings-section" aria-labelledby={heading}>
      <h2 id={heading}>How this Mac serves</h2>
      <fieldset className={styles.choices} aria-labelledby={heading} disabled={paired}>
        {servingChoices.map((choice) => (
          <ChoiceCard
            key={choice.mode}
            name={group}
            checked={draft === choice.mode}
            onSelect={() => setDraft(choice.mode)}
            title={choice.title}
            detail={servingDetail(choice.mode, local)}
            badge={choice.mode === 'both' ? 'Recommended' : undefined}
            marker={saved === choice.mode ? 'Saved' : undefined}
          />
        ))}
      </fieldset>
      {paired ? (
        <p className={styles.note}>
          This Mac is in a pair, which serves its own way.{' '}
          {navigate && (
            <button className="text-link" onClick={() => navigate('cluster')}>
              Clusters <ArrowUpRight size={13} />
            </button>
          )}
        </p>
      ) : (
        <>
          {changed &&
            !keep.length &&
            (choices.length ? (
              <label className="setting-row">
                <span>
                  <strong>Model</strong>
                  <small>Choose a model to serve.</small>
                </span>
                <select value={pick} onChange={(event) => setChosen(event.target.value)}>
                  {choices.map((model) => (
                    <option key={model.id} value={model.id}>
                      {model.display_name}
                    </option>
                  ))}
                </select>
              </label>
            ) : (
              <p className={styles.note}>No model to serve yet. Get one in Models.</p>
            ))}
          <div className={styles.apply}>
            <Button
              variant="primary"
              disabled={!changed || !models.length || backend.busy}
              onClick={() => void backend.act({ action: 'start', models, ...startFlag[draft] })}
            >
              <Play size={14} /> Apply
            </Button>
            <small>
              {saved ? '' : 'No choice is saved yet. '}
              {changed && models.length
                ? `Applying ${verb} serving with ${names(models.map((id) => modelName(state.models, id)))}.`
                : `Applying ${verb} serving.`}
            </small>
          </div>
        </>
      )}
    </section>
  );
}
