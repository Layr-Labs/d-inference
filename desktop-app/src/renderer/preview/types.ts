import type { Action, Operation, Resource, Snapshot } from '../../shared/contracts';

// The development preview's state, shared by every feature's preview module.
export interface PreviewStore {
  get(): Snapshot;
  set(next: Snapshot): void;
}

// One feature's part of the development preview: the resources it serves, the actions it
// handles (undefined falls through to the generic preview), and changes to the starting snapshot.
export interface FeaturePreview {
  resources?(): Partial<Record<Resource, unknown>>;
  act?(store: PreviewStore, action: Action): Promise<Operation | undefined>;
  snapshot?(snapshot: Snapshot): Snapshot;
}

// Unit tests import the preview without a document; they see no query.
export const previewParam = (name: string) =>
  typeof location === 'undefined' ? null : new URLSearchParams(location.search).get(name);

export function previewOperation(
  action: Action,
  state: Operation['state'] = 'succeeded',
  message = 'Preview action complete',
): Operation {
  return {
    id: crypto.randomUUID(),
    action: action.action,
    state,
    started_at: Date.now() / 1000,
    ...(state === 'running' ? {} : { finished_at: Date.now() / 1000 }),
    message,
    cancellable: false,
  };
}

// Records an operation in the snapshot, as the native API does.
export function recordOperation(store: PreviewStore, operation: Operation, next = store.get()) {
  store.set({
    ...next,
    operations: [operation, ...next.operations.filter((item) => item.id !== operation.id)].slice(
      0,
      10,
    ),
  });
  return operation;
}
