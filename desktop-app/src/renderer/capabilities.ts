import type { Snapshot } from '../shared/contracts';

// Features a runtime offers only when `Snapshot.capabilities` lists them: without one it refuses
// the feature's resources and actions, so the app hides the feature or says it needs a newer
// Darkbloom CLI instead.
export type Capability =
  | 'cluster'
  | 'cluster_session'
  | 'sandbox'
  | 'waitlists'
  | 'local_serving'
  | 'tool_setup'
  | 'update_rollback';

export const supports = (state: Snapshot | undefined, capability: Capability) =>
  !!state?.capabilities?.includes(capability);
