import { ArrowRight, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { Action, Snapshot } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Button, External, Notice } from '../UI';
import { AdvancedOptions } from './AdvancedOptions';
import { ServingSummary } from './ServingSummary';
import { pinnedMemory, startingModel } from '../../models/selection';
import {
  methodFor,
  pairBlocked,
  pairLead,
  pairStartable,
  startAction,
  startModels,
  usablePins,
  type StartMethod,
} from './startPlan';
import { useStartServing } from './useStartServing';
import styles from './startServing.module.css';
import { networkEarnings, recommendedModels } from '../../features/models/recommendations';
import { RecommendedModels } from '../../features/models/RecommendedModels';

const copy: Record<StartMethod, { lead: string; start: string; empty: string }> = {
  autopilot: {
    lead: 'Turn on Autopilot once and Darkbloom runs this Mac for you.',
    start: 'Start serving with Autopilot',
    empty: 'No model on Darkbloom fits this Mac yet.',
  },
  manual: {
    lead: 'Start with models you choose. Autopilot can take over after an update.',
    start: 'Start serving',
    empty: 'Choose a model to serve.',
  },
};

// A paired Mac starts its pair (`startAction`), never Autopilot, which serves one Mac: the plain
// start's page, with the pair's words, and why there is no Start where the pair needs Terminal.
const pairCopy = (pair: NonNullable<Snapshot['pair']>) => ({
  ...copy.manual,
  lead: pairLead(pair),
  empty: pairBlocked(pair),
});

function accountLine(snapshot: Snapshot) {
  return snapshot.linked
    ? 'Your Darkbloom account is linked.'
    : 'Link your Darkbloom account first. Serving needs it.';
}

export function StartServing({
  backend,
  snapshot,
  link,
  done,
}: {
  backend: BackendState;
  snapshot: Snapshot;
  link: () => void;
  done: () => void;
}) {
  const [pinned, setPinned] = useState<string[]>(() => {
    if (!snapshot.capabilities || snapshot.capabilities.includes('autopilot')) return [];
    const model = startingModel(snapshot);
    return model ? [model.id] : [];
  });
  const [open, setOpen] = useState(false);
  const starting = startingModel(snapshot);
  const serving = useStartServing(backend, done, () =>
    setPinned((current) => (current.length || !starting ? current : [starting.id])),
  );
  const manualOnly = !!snapshot.capabilities && !snapshot.capabilities.includes('autopilot');
  const pair = snapshot.pair;
  const method = methodFor(serving.rejected || manualOnly || !!pair);
  const text = pair ? pairCopy(pair) : copy[method];
  const pins = usablePins(snapshot, pinned);
  const network = networkEarnings(backend.network);
  const recommended =
    method === 'autopilot' && !pins.length ? recommendedModels(snapshot.models, network) : [];
  const showRecommendations = recommended.length > 0;
  const empty = pair ? !pairStartable(pair) : !startModels(snapshot, method, pinned).length;
  const tooLarge = pinnedMemory(snapshot, pins).exceeds;
  const running = snapshot.operations.find((operation) => operation.state === 'running');
  // Serving needs a linked account: an unlinked Mac goes back to link it first.
  const serve = (action: Action) => (snapshot.linked ? void serving.serve(action) : link());
  return (
    <>
      <h2>Ready to serve.</h2>
      {!showRecommendations && (
        <>
          <p>{text.lead}</p>
          {!(pair && empty) && <ServingSummary snapshot={snapshot} method={method} pinned={pins} />}
        </>
      )}
      {serving.rejected && method === 'manual' && (
        <div className={styles.fallback} role="alert">
          <strong>Autopilot isn’t available in this version of Darkbloom.</strong>
          <span>You can still start serving without it, with the models you choose.</span>
          {!open && (
            <Button onClick={() => setOpen(true)}>
              Choose models manually <ArrowRight size={15} />
            </Button>
          )}
        </div>
      )}
      {serving.problem && <Notice>{serving.problem}</Notice>}
      {showRecommendations ? (
        <RecommendedModels
          snapshot={snapshot}
          models={recommended}
          earnings={network}
          setup
          busy={backend.busy || serving.phase !== 'idle'}
          onStart={(action) => serve({ ...action, endpoint: true })}
        />
      ) : (
        <Button
          variant="primary"
          className={styles.start}
          disabled={empty || tooLarge || backend.busy || serving.phase !== 'idle'}
          onClick={() => serve(startAction(snapshot, method, pinned))}
        >
          {serving.phase === 'starting' ? (
            <>
              <LoaderCircle className="spin" size={16} /> Starting…
            </>
          ) : (
            <>
              {text.start} <ArrowRight size={16} />
            </>
          )}
        </Button>
      )}
      <div className={styles.note} role="status">
        {serving.phase === 'starting' && running?.message
          ? running.message
          : empty
            ? text.empty
            : accountLine(snapshot)}
      </div>
      <p className="terms-note">
        By turning on, you agree to our <External target="terms">Terms of Service</External>
      </p>
      <div className={styles.more} hidden={!!pair}>
        <AdvancedOptions
          snapshot={snapshot}
          open={open}
          onToggle={() => setOpen(!open)}
          method={method}
          pinned={pinned}
          onPinned={setPinned}
        />
      </div>
    </>
  );
}
