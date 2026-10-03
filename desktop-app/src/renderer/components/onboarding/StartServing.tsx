import { ArrowRight, LoaderCircle } from 'lucide-react';
import { useState } from 'react';
import type { Snapshot } from '../../../shared/contracts';
import type { BackendState } from '../../useBackend';
import { Button, External, Notice } from '../UI';
import { AdvancedOptions } from './AdvancedOptions';
import { LinkPanel } from './LinkPanel';
import type { ContributionMode } from './ModeChoice';
import { ServingSummary } from './ServingSummary';
import { pinnedMemory, startingModel } from '../../models/selection';
import { methodFor, startAction, startModels, type StartMethod } from './startPlan';
import { useStartServing } from './useStartServing';
import styles from './startServing.module.css';

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
  local: {
    lead: 'Run models for your own apps. This Mac won’t serve the network.',
    start: 'Start local models',
    empty: 'Pin a model to run it locally.',
  },
};

function accountLine(snapshot: Snapshot, method: StartMethod) {
  if (method === 'local') return 'Local only doesn’t need a Darkbloom account.';
  return snapshot.linked
    ? 'Your Darkbloom account is linked.'
    : 'First you’ll link your Darkbloom account in the browser, then serving starts.';
}

export function StartServing({
  backend,
  snapshot,
  done,
}: {
  backend: BackendState;
  snapshot: Snapshot;
  done: () => void;
}) {
  const [mode, setMode] = useState<ContributionMode>('network');
  const [pinned, setPinned] = useState<string[]>([]);
  const [open, setOpen] = useState(false);
  const starting = startingModel(snapshot);
  const serving = useStartServing(backend, done, () =>
    setPinned((current) => (current.length || !starting ? current : [starting.id])),
  );
  const method = methodFor(mode, serving.rejected);
  const text = copy[method];
  const empty = !startModels(snapshot, method, pinned).length;
  const tooLarge = pinnedMemory(snapshot, pinned).exceeds;
  const running = snapshot.operations.find((operation) => operation.state === 'running');
  return (
    <>
      <h2>Ready to serve.</h2>
      <p>{text.lead}</p>
      <ServingSummary snapshot={snapshot} method={method} pinned={pinned} />
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
      {serving.phase === 'linking' ? (
        <LinkPanel link={snapshot.link} cancel={serving.cancelLink} />
      ) : (
        <>
          <Button
            variant="primary"
            className={styles.start}
            disabled={empty || tooLarge || backend.busy || serving.phase !== 'idle'}
            onClick={() =>
              void serving.serve(
                startAction(snapshot, method, pinned),
                method !== 'local' && !snapshot.linked,
              )
            }
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
          <div className={styles.note} role="status">
            {serving.phase === 'starting' && running?.message
              ? running.message
              : empty
                ? text.empty
                : accountLine(snapshot, method)}
          </div>
        </>
      )}
      <p className="terms-note">
        By turning on, you agree to our <External target="terms">Terms of Service</External>
      </p>
      <div className={styles.more}>
        <AdvancedOptions
          snapshot={snapshot}
          open={open}
          onToggle={() => setOpen(!open)}
          method={method}
          mode={mode}
          onMode={setMode}
          pinned={pinned}
          onPinned={setPinned}
        />
        <button className="text-link" onClick={done}>
          Explore the app first <ArrowRight size={13} />
        </button>
      </div>
    </>
  );
}
