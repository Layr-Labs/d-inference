import type { Snapshot } from '../../../../shared/contracts';
import { modelName } from '../../../models/facts';
import styles from './overview.module.css';

export function ServingModels({
  state,
  models,
  onManage,
  inline = false,
}: {
  state: Snapshot;
  models: string[];
  onManage?: () => void;
  inline?: boolean;
}) {
  const names = models.map((id) => modelName(state.models, id));
  const chips = (
    <div className={styles.modelNames}>
      {names.length ? (
        names.map((name) => <span key={name}>{name}</span>)
      ) : (
        <span>No serving models reported</span>
      )}
    </div>
  );
  if (inline)
    return (
      <section className={styles.inline} aria-label="Serving models">
        <h2>Serving models</h2>
        {chips}
      </section>
    );
  return (
    <section className={styles.section}>
      <div className={styles.heading}>
        <h2>Serving models</h2>
        {onManage && (
          <button className="text-link" onClick={onManage}>
            Manage models
          </button>
        )}
      </div>
      {chips}
    </section>
  );
}
