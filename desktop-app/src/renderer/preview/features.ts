import type { Action, Operation, Resource, Snapshot } from '../../shared/contracts';
import { chatPreview } from './chat';
import { clusterPreview } from './cluster';
import { localServingPreview } from './localServing';
import { sandboxPreview } from './sandbox';
import type { FeaturePreview, PreviewStore } from './types';
import { waitlistsPreview } from './waitlists';

// Every feature's preview module, in one place so preview.ts stays feature-neutral.
const features: FeaturePreview[] = [
  clusterPreview,
  sandboxPreview,
  waitlistsPreview,
  chatPreview,
  localServingPreview,
];

export function featureResources(): Partial<Record<Resource, unknown>> {
  return Object.assign({}, ...features.map((feature) => feature.resources?.() ?? {}));
}

export async function featureAction(
  store: PreviewStore,
  action: Action,
): Promise<Operation | undefined> {
  for (const feature of features) {
    const handled = await feature.act?.(store, action);
    if (handled) return handled;
  }
  return undefined;
}

export function withFeatureSnapshots(snapshot: Snapshot): Snapshot {
  return features.reduce((next, feature) => feature.snapshot?.(next) ?? next, snapshot);
}
