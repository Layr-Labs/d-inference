import type { Action, DesktopAPI, Snapshot, Resource } from '../shared/contracts';
import { previewInsights } from './previewInsights';
import { publicOrFixture } from './previewNetwork';
import { previewLink, withPreviewAccount } from './previewAccount';
import { previewModelAction, simulateAutopilot, withPreviewAutopilot } from './previewAutopilot';
import { previewWaitlist, withOnboardingScenario } from './previewEligibility';
import { previewRequestHistory, previewSamples } from './previewActivity';
import { previewHardwareLoad, previewHardwareStream } from './previewHardware';
import { previewResources } from './previewResources';
import { previewCloud, previewSnapshot } from './previewSnapshot';

// Explicit development-only fixture. Never used as a fallback for failed live data.
const now = Date.now() / 1000;
const requestHistory = previewRequestHistory(now);
let snapshot: Snapshot = withPreviewAutopilot(
  withPreviewAccount(withOnboardingScenario(previewSnapshot(now, previewSamples(now)))),
);
const listeners = new Set<(state: Snapshot) => void>();
const store = {
  get: () => snapshot,
  set(next: Snapshot) {
    snapshot = next;
    listeners.forEach((fn) => fn(structuredClone(snapshot)));
  },
};
const cloud = previewCloud(now);
export const previewAPI: DesktopAPI = {
  async read<T>(resource: Resource) {
    snapshot.observed_at = Date.now() / 1000;
    snapshot.activity.sampled_at = snapshot.observed_at;
    cloud.observed_at = snapshot.observed_at;
    cloud.machines[0].observed_at = snapshot.observed_at - 25;
    const data: Partial<Record<Resource, unknown>> = {
      ...previewResources(),
      'insights-week': previewInsights('7d'),
      'insights-month': previewInsights('30d'),
      state: structuredClone(snapshot),
      cloud,
      'request-history': requestHistory,
      hardware: previewHardwareLoad(snapshot.observed_at, snapshot.state === 'running'),
    };
    return (await publicOrFixture(resource, data[resource])) as T;
  },
  async act(action: Action) {
    if (action.action === 'waitlist') await previewWaitlist();
    const handled = await previewModelAction(store, action);
    if (handled) return handled;
    if (action.action === 'link')
      snapshot = previewLink(snapshot, (update) => {
        snapshot = update(snapshot);
        listeners.forEach((fn) => fn(structuredClone(snapshot)));
      });
    if (action.action === 'stop')
      snapshot = { ...snapshot, state: 'stopped', readiness: 'Provider stopped' };
    if (action.action === 'start' || action.action === 'restart')
      snapshot = { ...snapshot, state: 'running', readiness: 'Connected and ready for requests' };
    if (action.action === 'switch')
      snapshot.models = snapshot.models.map((model) => ({
        ...model,
        serving: action.models.includes(model.id),
        loaded: action.models.includes(model.id),
      }));
    if (action.action === 'settings') snapshot.settings = { ...snapshot.settings, ...action };
    const operation = {
      id: crypto.randomUUID(),
      action: action.action,
      state: 'succeeded' as const,
      started_at: Date.now() / 1000,
      message: 'Preview action complete',
      cancellable: false,
    };
    snapshot = { ...snapshot, operations: [operation, ...snapshot.operations].slice(0, 10) };
    listeners.forEach((fn) => fn(structuredClone(snapshot)));
    return operation;
  },
  async status() {
    return { state: 'ready' };
  },
  async install() {},
  async copy(text) {
    await navigator.clipboard.writeText(text);
  },
  async openExternal() {},
  async updateStatus() {
    return { state: 'idle' };
  },
  async checkUpdate() {
    return { state: 'idle' };
  },
  async applyUpdate() {},
  onState(callback) {
    listeners.add(callback);
    const stopAutopilot = simulateAutopilot(store);
    const timer = setInterval(() => {
      if (snapshot.state === 'running') {
        snapshot.activity.tokens = (BigInt(snapshot.activity.tokens || '0') + 324n).toString();
        snapshot.activity.requests = (BigInt(snapshot.activity.requests || '0') + 1n).toString();
        snapshot.activity.models = snapshot.activity.models?.map((model, index) => ({
          ...model,
          running: (index === 0 ? 15 : 6) + (Math.floor(Date.now() / 2000 + index) % 5),
        }));
      }
      snapshot.observed_at = Date.now() / 1000;
      snapshot.activity.sampled_at = snapshot.observed_at;
      callback(structuredClone(snapshot));
    }, 2000);
    return () => {
      clearInterval(timer);
      stopAutopilot();
      listeners.delete(callback);
    };
  },
  onStatus() {
    return () => {};
  },
  onNavigate() {
    return () => {};
  },
  onHardware(callback) {
    return previewHardwareStream(callback, () => snapshot.state === 'running');
  },
};
