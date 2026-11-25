import type { BackendState } from '../../src/after/desktop-app/src/renderer/useBackend';
import type { Snapshot } from '../../src/after/desktop-app/src/shared/contracts';
import { backendWith } from '../../src/after/desktop-app/tests/onboardingFixtures';
import { bridges, type Version } from './bridge';

export { snapshot, models, eightGBMac } from '../../src/after/desktop-app/tests/onboardingFixtures';
export { poolSnapshot } from '../../src/after/desktop-app/tests/modelsFixtures';
export { previewBackend } from '../../src/after/desktop-app/tests/previewBackend';

/** A backend whose actions are recorded in that version's "Sent to the runtime" log. */
export function backendFor(
  version: Version,
  state: Snapshot | undefined,
  overrides: Partial<BackendState> = {},
): BackendState {
  return backendWith(state, {
    act: async (action) => {
      bridges[version].record(JSON.stringify(action));
      return true;
    },
    ...overrides,
  });
}
