import { Sparkles } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { startingModel } from '../../models/selection';
import styles from './autopilot.module.css';

// Turning on mirrors `darkbloom autopilot enable`: start with Autopilot on the models serving
// now, or the starting model when nothing serves. Saved pins are kept by the runtime.
export function enableAction(snapshot: Snapshot) {
  const serving = snapshot.models.filter((model) => model.serving && model.downloaded);
  const fallback = startingModel(snapshot);
  const models = serving.length ? serving.map((model) => model.id) : fallback ? [fallback.id] : [];
  return { action: 'autopilot' as const, models, pinned: [], endpoint: !!snapshot.endpoint };
}

export function TurnOnAutopilot({
  snapshot,
  working,
  onEnable,
}: {
  snapshot: Snapshot;
  working?: string;
  onEnable: () => void;
}) {
  return (
    <section className={styles.offer} aria-label="Autopilot">
      <span className={styles.icon}>
        <Sparkles size={18} />
      </span>
      <div>
        <strong>Let Autopilot run this Mac’s models</strong>
        <p>
          You choose which models live on this Mac: downloaded models form Autopilot’s pool, and you
          can pin the ones that must always stay loaded. Autopilot decides which ones to load into
          memory as demand changes.
        </p>
      </div>
      <Button disabled={!!working || !enableAction(snapshot).models.length} onClick={onEnable}>
        {working ?? 'Turn on Autopilot'}
      </Button>
    </section>
  );
}
