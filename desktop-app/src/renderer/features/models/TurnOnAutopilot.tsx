import { Sparkles } from 'lucide-react';
import type { Snapshot } from '../../../shared/contracts';
import { Button } from '../../components/UI';
import { servesNetwork, startingModel } from '../../models/selection';
import styles from './autopilot.module.css';

// Turning on mirrors `darkbloom autopilot enable`: start with Autopilot on the models serving
// now, or the starting model when nothing serves. Saved pins are kept by the runtime.
export function enableAction(snapshot: Snapshot) {
  const serving = snapshot.models.filter(
    (model) => model.serving && model.downloaded && servesNetwork(model),
  );
  const fallback = startingModel(snapshot);
  const models = serving.length ? serving.map((model) => model.id) : fallback ? [fallback.id] : [];
  const downloads = snapshot.models
    .filter((model) => models.includes(model.id) && !model.downloaded)
    .map((model) => model.id);
  return {
    action: 'autopilot' as const,
    models,
    pinned: [],
    ...(downloads.length ? { downloads } : {}),
    endpoint: !!snapshot.endpoint,
  };
}

// Autopilot serves the network, so an unlinked Mac is linked first: the app shows a code and the
// user opens the link page to approve it. Say so before the click.
export const linkFirst =
  'Autopilot needs this Mac linked to your Darkbloom account. You’ll get a code here and open the link page in your browser to approve it. Once you approve, Autopilot starts and any downloads begin.';

export function TurnOnAutopilot({
  snapshot,
  working,
  busy = false,
  onEnable,
}: {
  snapshot: Snapshot;
  working?: string;
  /** Another model or runtime operation is in flight. */
  busy?: boolean;
  onEnable: () => void;
}) {
  return (
    <section className={styles.offer} aria-label="Autopilot">
      <span className={styles.icon}>
        <Sparkles size={18} />
      </span>
      <div>
        <strong>Autopilot</strong>
        <small>Choose downloads. Autopilot manages what’s loaded.</small>
        {!snapshot.linked && <small>{linkFirst}</small>}
      </div>
      <Button
        disabled={busy || !!working || !enableAction(snapshot).models.length}
        onClick={onEnable}
      >
        {working ?? (snapshot.linked ? 'Turn on Autopilot' : 'Link this Mac & turn on Autopilot')}
      </Button>
    </section>
  );
}
