import type { NativeModel, Snapshot } from '../../../shared/contracts';
import type { LocalServing, RequestRoute, ServingMode } from '../../../shared/localServing';
import { servesNetwork } from '../../models/selection';

// Studio's words are the CLI's own (`ServingQuestion`, `LocalFirstWords`, `MeFirstWords`,
// `RouteChoiceFlow`, `LocalRouterAccountKeyFormat` in provider-swift/Sources), so the app and
// `darkbloom start`, `status` and `route` say the same thing.

export type StudioCapability = 'local_serving' | 'tool_setup' | 'update_rollback';

export const supports = (state: Snapshot, capability: StudioCapability) =>
  !!state.capabilities?.includes(capability);

// `Snapshot.local`, only from a runtime that offers local-first serving.
export const localServing = (state: Snapshot): LocalServing | undefined =>
  supports(state, 'local_serving') ? state.local : undefined;

// "1 minute", "2 minutes".
export const minutes = (count: number) => (count === 1 ? '1 minute' : `${count} minutes`);

// The start question's three answers, in its order.
export const servingChoices: { mode: ServingMode; title: string }[] = [
  { mode: 'local', title: 'Only me' },
  { mode: 'network', title: 'Darkbloom network' },
  { mode: 'both', title: 'Both, me first' },
];

// The question's line for each answer; Both says so when me first is off.
export function servingDetail(
  mode: ServingMode,
  local: Pick<LocalServing, 'me_first' | 'me_first_idle_minutes'>,
) {
  if (mode === 'local')
    return 'Darkbloom never contacts this Mac. Your tools use this Mac’s own API.';
  if (mode === 'network') return 'This Mac serves Darkbloom and earns while it runs.';
  return local.me_first
    ? 'This Mac serves Darkbloom while you aren’t using it. When you use it, Darkbloom traffic ' +
        `pauses until you’ve been idle for ${minutes(local.me_first_idle_minutes)}.`
    : 'Darkbloom keeps serving while you use this Mac (me first is off).';
}

// Only me runs any model on this Mac; the network routes only catalog models.
export const servableModels = (state: Snapshot, mode: ServingMode): NativeModel[] =>
  state.models.filter(
    (model) => model.downloaded && (mode === 'local' ? model.eligible : servesNetwork(model)),
  );

// The models serving now that the chosen way can serve; applying keeps them.
export const servingNow = (state: Snapshot, mode: ServingMode) =>
  servableModels(state, mode).filter((model) => model.serving);

// "A", "A and B", "A, B and C".
export function names(items: string[]) {
  if (items.length < 2) return items.join('');
  return `${items.slice(0, -1).join(', ')} and ${items.at(-1)}`;
}

export const meFirstRange = { min: 1, max: 120 };

// Whole minutes from 1 to 120, else undefined.
export function idleMinutes(value: string) {
  const text = value.trim();
  if (!/^\d+$/.test(text)) return undefined;
  const count = Number(text);
  return count >= meFirstRange.min && count <= meFirstRange.max ? count : undefined;
}

// When Darkbloom comes back if you stay idle, `seconds` from now.
export function backIn(seconds: number) {
  if (seconds <= 0) return 'back any moment now';
  if (seconds < 60) return 'back in under a minute if you stay idle';
  const total = Math.floor((seconds + 30) / 60);
  const hours = Math.floor(total / 60);
  const rest = minutes(total % 60);
  const span =
    hours === 0
      ? rest
      : `${hours === 1 ? '1 hour' : `${hours} hours`}${total % 60 ? ` ${rest}` : ''}`;
  return `back in about ${span} if you stay idle`;
}

// The start question's follow-up, with the local-first guide's line for each answer.
export const routeChoices: { route: RequestRoute; title: string; detail: string }[] = [
  { route: 'this-mac', title: 'Only this Mac', detail: 'This Mac’s answer, always.' },
  { route: 'my-macs', title: 'Only my Macs (free)', detail: 'Your other Macs, at no cost.' },
  {
    route: 'my-macs-first',
    title: 'My Macs first',
    detail: 'Your other Macs, then the Darkbloom network, billed to your balance.',
  },
];

// The saved route, else this Mac only or, once an account key is saved, only my Macs.
export const effectiveRoute = (local: LocalServing): RequestRoute =>
  local.route ?? (local.route_key ? 'my-macs' : 'this-mac');

// Why a pasted value can't be an account API key, in the CLI's words; undefined when it can be.
// The CLI trims spaces and line breaks around the key first, and so does the app.
export function keyRefusal(key: string) {
  if (!key) return 'No key was given.';
  if (key.length > 512) return 'That is longer than any Darkbloom API key.';
  if ([...key].some((char) => char.charCodeAt(0) <= 0x20 || char.charCodeAt(0) >= 0x7f))
    return 'An API key has no spaces, line breaks or non-ASCII characters.';
  if (key.startsWith('dk-local-'))
    return 'That is this Mac’s local API key; use an account API key from the Darkbloom console.';
  return undefined;
}

const loopback = (host: string) =>
  host === 'localhost' || host === '::1' || /^127(?:\.\d{1,3}){3}$/.test(host);

// Where the local API answers: this Mac only on a loopback address (the default), else the
// local network too.
export const reach = (bind: string | null | undefined) =>
  loopback(bind || '127.0.0.1')
    ? 'Accessible only on this Mac.'
    : 'Accessible on your local network.';

export const address = (bind: string | null | undefined, port: number) => {
  const host = bind || '127.0.0.1';
  return `${host.includes(':') ? `[${host}]` : host}:${port}`;
};

export const toolCommand = { opencode: 'darkbloom --opencode', hermes: 'darkbloom --hermes' };
export const toolName = { opencode: 'OpenCode', hermes: 'Hermes' };
