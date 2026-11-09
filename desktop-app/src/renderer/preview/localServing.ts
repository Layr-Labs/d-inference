import type { Snapshot } from '../../shared/contracts';
import type { LocalServing, ServingMode } from '../../shared/localServing';
import { keyRefusal, routeChoices } from '../features/studio/words';
import { previewOperation, previewParam, recordOperation, type FeaturePreview } from './types';

// Development preview of local-first serving: a `Snapshot.local` fixture, the capabilities that go
// with it and simulated actions in the CLI's words. Never used for live data. `&local=only-me`,
// `network` or `both` (the default) is the saved choice; `&local=paused` is Both, me first with
// Darkbloom paused for you; `&local=unsupported` is a runtime without any of it. No account key is
// saved until one is entered, and an entered key is checked for its shape only and never kept.
const scenario = previewParam('local');
const modes: Record<string, ServingMode> = {
  'only-me': 'local',
  network: 'network',
  both: 'both',
  paused: 'both',
};
const capabilities = ['local_serving', 'tool_setup', 'update_rollback'];
// A snapshot with no capability list is a runtime from before the list, which the app reads as
// offering Autopilot and the waitlist: they stay offered once the list exists.
const listless = ['autopilot', 'waitlist'];
const port = 8001;

const endpointFor = (mode: ServingMode, models: string[]): Snapshot['endpoint'] =>
  mode === 'network'
    ? undefined
    : { base_url: `http://127.0.0.1:${port}/v1`, authenticated: true, models };

const settle = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export const localServingPreview: FeaturePreview = {
  snapshot(snapshot) {
    if (scenario === 'unsupported') return snapshot;
    const mode = modes[scenario ?? ''] ?? 'both';
    const local: LocalServing = {
      mode,
      me_first: true,
      me_first_idle_minutes: 2,
      route: null,
      route_key: false,
      port,
      bind: '127.0.0.1',
      paused_until: scenario === 'paused' ? snapshot.observed_at + 100 : null,
    };
    return {
      ...snapshot,
      capabilities: [
        ...(snapshot.capabilities ?? listless),
        ...capabilities.filter((name) => !snapshot.capabilities?.includes(name)),
      ],
      local,
      endpoint: endpointFor(mode, snapshot.endpoint?.models ?? snapshot.machine.models),
    };
  },
  async act(store, action) {
    const state = store.get();
    const local = state.local;
    if (!local) return undefined;
    const done = (message: string, next: Snapshot = store.get()) =>
      recordOperation(store, previewOperation(action, 'succeeded', message), next);
    const refused = (message: string) =>
      recordOperation(store, previewOperation(action, 'failed', message));
    // The snapshot as it is now, after a simulated wait, with `[local]` changed.
    const latest = (change: Partial<LocalServing>): Snapshot => {
      const now = store.get();
      return { ...now, local: { ...now.local!, ...change } };
    };
    switch (action.action) {
      case 'start': {
        // A start that names no way to serve is the shared preview's.
        const mode = action.local
          ? 'local'
          : action.network
            ? 'network'
            : action.endpoint
              ? 'both'
              : undefined;
        if (!mode) return undefined;
        return done('Preview action complete', {
          ...state,
          state: 'running',
          readiness: 'Connected and ready for requests',
          local: { ...local, mode, paused_until: null },
          endpoint: endpointFor(mode, action.models),
          models: state.models.map((model) => ({
            ...model,
            serving: action.models.includes(model.id),
            loaded: action.models.includes(model.id),
          })),
        });
      }
      case 'route': {
        await settle(400);
        if (action.route !== 'this-mac' && !store.get().local?.route_key)
          return refused(
            `✗ Not saved: \`darkbloom route ${action.route}\` passes your requests on with your account API key, and this Mac has none saved.`,
          );
        const meaning = routeChoices.find((choice) => choice.route === action.route)!.detail;
        return done(
          `✓ Saved. Your local API uses it now.\n${meaning}`,
          latest({ route: action.route }),
        );
      }
      case 'route_key': {
        const refusal = keyRefusal(action.key.trim());
        await settle(700);
        if (refusal) return refused(`✗ Not saved: ${refusal}`);
        return done(
          '✓ Account key saved in this Mac’s Keychain. Darkbloom accepted it; your Macs serve 2 models now.\nYour local API uses it now.',
          latest({ route_key: true }),
        );
      }
      case 'local_settings': {
        await settle(400);
        const minutes = action.me_first_idle_minutes;
        if (!Number.isInteger(minutes) || minutes < 1 || minutes > 120)
          return refused(
            `[local] me_first_idle_minutes must be a whole number of minutes from 1 to 120, not ${minutes}.`,
          );
        return done(
          'Saved. It applies when serving restarts.',
          latest({
            me_first: action.me_first,
            me_first_idle_minutes: minutes,
            ...(action.me_first ? {} : { paused_until: null }),
          }),
        );
      }
      case 'tool_setup': {
        const tool = action.tool === 'opencode' ? 'OpenCode' : 'Hermes';
        await settle(1200);
        if (!store.get().endpoint)
          return refused(
            `✗ This Mac serves only the Darkbloom network, so ${tool} has no local address to use.`,
          );
        return done(
          action.tool === 'opencode'
            ? [
                '✓ OpenCode can use Darkbloom: 2 models.',
                '  Changed: ~/.config/opencode/opencode.jsonc (added the "darkbloom" provider; nothing else changed)',
                '  Pick Darkbloom once with /models; OpenCode remembers it.',
              ].join('\n')
            : [
                '✓ Hermes can use Darkbloom: 2 models.',
                '  Changed: ~/.hermes/config.yaml (added the "darkbloom" provider)',
                '  New Hermes chats now use Darkbloom’s GPT-OSS 20B. Switch back: hermes model',
              ].join('\n'),
        );
      }
      case 'update_rollback': {
        await settle(1500);
        return done(
          `Rolled back: v${state.version} -> v0.9.15.\nv${state.version} is quarantined on this Mac: automatic updates skip it, and the next newer release installs normally.`,
        );
      }
      default:
        return undefined;
    }
  },
};
