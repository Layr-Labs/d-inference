import type { Route } from '../../../../shared/contracts';
import type { BackendState } from '../../../useBackend';
import {
  publishedVersions,
  releaseStatus,
  runtimeVersion,
  updateAvailable,
} from '../../updates/version';
import { assessReadiness } from './readiness';
import { ReadinessHealth } from './ReadinessHealth';
import { MemoryHealth } from './MemoryHealth';
import { FanHealth } from './FanHealth';
import { NextSteps } from './NextSteps';
import styles from './overview.module.css';

export function HealthBar({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  const installed = runtimeVersion(state);
  const { latest, minimum } = publishedVersions(backend);
  const readiness = assessReadiness({
    status: backend.status,
    state,
    update: {
      required: releaseStatus(installed, latest, minimum) === 'required',
      available: updateAvailable(installed, latest, minimum),
    },
  });
  return (
    <section className={styles.health} aria-label="Health">
      <div className={styles.cells}>
        <ReadinessHealth
          tone={readiness.tone}
          status={
            backend.status.state === 'ready'
              ? state.readiness
              : backend.status.message || 'Connecting to the native runtime…'
          }
          summary={readiness.summary}
        />
        <MemoryHealth memory={state.memory} />
        <FanHealth cooling={backend.cooling} />
      </div>
      {readiness.steps.length > 0 && (
        <NextSteps steps={readiness.steps} backend={backend} navigate={navigate} />
      )}
    </section>
  );
}
