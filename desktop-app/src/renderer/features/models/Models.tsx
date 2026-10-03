import { Info } from 'lucide-react';
import { Notice } from '../../components/UI';
import type { BackendState } from '../../useBackend';
import { AutopilotModels } from './AutopilotModels';
import { ManualModels } from './ManualModels';
import { modelsMode } from './pool';
import { enableAction, TurnOnAutopilot } from './TurnOnAutopilot';
import { useModelActions } from './useModelActions';
import styles from './autopilot.module.css';

export function Models({
  backend,
  embedded = false,
}: {
  backend: BackendState;
  embedded?: boolean;
}) {
  const state = backend.state!;
  const actions = useModelActions(backend);
  const mode = modelsMode(state);
  if (mode === 'autopilot')
    return <AutopilotModels backend={backend} actions={actions} embedded={embedded} />;
  return (
    <ManualModels
      backend={backend}
      embedded={embedded}
      note={
        mode === 'unsupported' ? (
          <p className={styles.note}>
            <Info size={14} /> Autopilot needs a newer Darkbloom runtime. Until then, you choose
            which models serve.
          </p>
        ) : (
          <>
            {actions.problem && <Notice onClose={actions.dismiss}>{actions.problem}</Notice>}
            <TurnOnAutopilot
              snapshot={state}
              working={actions.working.autopilot}
              onEnable={() => void actions.policy(enableAction(state), 'Turning on…')}
            />
          </>
        )
      }
    />
  );
}
