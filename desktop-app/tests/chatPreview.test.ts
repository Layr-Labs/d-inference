// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import {
  chatPreview,
  pieces,
  previewChatAPI,
  previewNetworkModels,
  routeModels,
} from '../src/renderer/preview/chat';
import type { PreviewStore } from '../src/renderer/preview/types';
import type { NetworkChatModel } from '../src/renderer/previewNetwork';
import { reasoningEfforts, type ChatEvent, type ChatRequest } from '../src/shared/chat';
import type { RequestRoute } from '../src/shared/localServing';
import { snapshot } from './onboardingFixtures';

// The preview's state: a Mac serving Both, me first, with this route and account key saved.
let state = snapshot();
const store: PreviewStore = { get: () => state, set: (next) => (state = next) };
const saved = (route: RequestRoute | null, route_key = route !== null && route !== 'this-mac') => {
  state = snapshot({
    local: {
      mode: 'both',
      me_first: true,
      me_first_idle_minutes: 2,
      route,
      route_key,
      port: 8001,
      bind: '127.0.0.1',
    },
  });
};
const api = previewChatAPI(store);
const listed = async () => (await api.chatModels()).models.map((model) => model.id);

const events: ChatEvent[] = [];
const started: string[] = [];
let off: () => void;
const ask = (model = 'gpt-oss-20b', extra: Partial<ChatRequest> = {}) =>
  api
    .chatSend({ model, messages: [{ role: 'user', content: 'Hello there' }], ...extra })
    .then((result) => {
      started.push(result.stream);
      return result;
    });
const preview = (query = '') => window.history.replaceState({}, '', `/?preview${query}`);

beforeEach(() => {
  vi.useFakeTimers();
  events.length = 0;
  off = api.onChat((event) => events.push(event));
  preview();
  saved(null);
});
afterEach(async () => {
  for (const stream of started.splice(0)) await api.chatCancel(stream);
  off();
  vi.useRealTimers();
});

it('lists this Mac’s models, one that reasons with every effort, while no route is saved', async () => {
  const list = await api.chatModels();
  expect(list.code).toBeUndefined();
  expect(list.models.map((model) => [model.id, model.owned_by, model.reasoning])).toEqual([
    ['gpt-oss-20b', 'this-mac', true],
    ['qwen3-vl-30b', 'this-mac', false],
  ]);
  expect(list.models[0].reasoning_efforts).toEqual([...reasoningEfforts]);
});

it('adds your Macs’ models with a key, and the network’s with My Macs first, as the route says', async () => {
  const yours = ['gpt-oss-20b', 'qwen3-vl-30b', 'gemma-4-26b'];
  saved(null, true);
  expect(await listed()).toEqual(yours);
  saved('my-macs');
  expect(await listed()).toEqual(yours);
  saved('this-mac', true);
  expect(await listed()).toEqual(yours.slice(0, 2));
  saved('my-macs-first');
  const list = await api.chatModels();
  // Under test the catalog is never read, so the network's models are the fallback's, less the
  // Gemma 4 26B alias your Macs already list.
  const network = previewNetworkModels().map(({ model }) => model);
  expect(network.map((model) => model.id)).toEqual([
    'gemma-4-26b',
    'EigenLabs/Qwen3.8-27B-4bit-mtp',
    'glm-5.3-flash',
    'mimo-v2.6-flash-mopd',
  ]);
  expect(list.models.slice(0, 3).map((model) => model.id)).toEqual(yours);
  expect(list.models.slice(3)).toEqual(network.slice(1));
  expect(list.models.slice(3).every((model) => model.owned_by === 'darkbloom')).toBe(true);
});

it('lists each model once and leaves out a network alias of a build this Mac serves', () => {
  const network = (id: string, builds = [id]): NetworkChatModel => ({
    model: { id, owned_by: 'darkbloom' },
    builds,
  });
  const listed = routeModels('my-macs-first', [
    network('gpt-oss-20b'),
    network('gemma-4-26b'),
    network('gpt-oss', ['gpt-oss-20b-mxfp4', 'gpt-oss-20b']),
    network('glm-5.3-flash'),
    network('glm-5.3-flash'),
  ]);
  expect(listed.map((model) => [model.id, model.owned_by])).toEqual([
    ['gpt-oss-20b', 'this-mac'],
    ['qwen3-vl-30b', 'this-mac'],
    ['gemma-4-26b', 'my-macs'],
    ['glm-5.3-flash', 'darkbloom'],
  ]);
  expect(routeModels('my-macs', [network('glm-5.3-flash')])).toHaveLength(3);
});

it('reasons in an answer from a network model the list says reasons', async () => {
  saved('my-macs-first');
  await api.chatModels();
  await ask('glm-5.3-flash');
  await vi.runAllTimersAsync();
  started.length = 0;
  expect(events.some((event) => event.type === 'reasoning')).toBe(true);
  expect(events.at(-1)?.type).toBe('done');
});

it('reads, reasons, then answers with a code block at a Mac’s pace', async () => {
  const { stream } = await ask();
  await vi.advanceTimersByTimeAsync(650);
  expect(events).toEqual([]);
  await vi.advanceTimersByTimeAsync(1_000);
  const early = events.length;
  // About 55 pieces a second while it reasons.
  expect(early).toBeGreaterThan(25);
  expect(early).toBeLessThan(60);
  await vi.runAllTimersAsync();
  started.length = 0;
  const kinds = events.map((event) => event.type);
  expect(kinds.indexOf('content')).toBeGreaterThan(kinds.lastIndexOf('reasoning'));
  expect(kinds.at(-1)).toBe('done');
  const text = events
    .filter((event): event is Extract<ChatEvent, { text: string }> => event.type === 'content')
    .map((event) => event.text)
    .join('');
  expect(text).toMatch(/```\w+\n[\s\S]+\n```/);
  expect(events.at(-1)).toEqual({
    stream,
    type: 'done',
    finish_reason: 'stop',
    usage: { prompt_tokens: 3, completion_tokens: events.length - 1 },
  });
});

it('answers without reasoning on a model that doesn’t reason', async () => {
  await ask('qwen3-vl-30b');
  await vi.runAllTimersAsync();
  started.length = 0;
  expect(events.some((event) => event.type === 'reasoning')).toBe(false);
  expect(events.at(-1)?.type).toBe('done');
});

it('stops on cancel, saying how much it wrote', async () => {
  const { stream } = await ask();
  await vi.advanceTimersByTimeAsync(1_000);
  const written = events.length;
  await api.chatCancel(stream);
  await vi.advanceTimersByTimeAsync(5_000);
  expect(events).toHaveLength(written + 1);
  expect(events.at(-1)).toEqual({
    stream,
    type: 'done',
    finish_reason: 'cancelled',
    usage: { completion_tokens: written },
  });
});

it('streams at most two answers at once, as the main process does', async () => {
  await ask();
  await ask();
  await expect(ask()).rejects.toThrow('Two answers are already streaming.');
  await expect(api.chatSend({ model: 'gpt-oss-20b', messages: [] })).rejects.toThrow(
    'Write a message first.',
  );
});

it('refuses each answer as a busy Mac does with &chat=fail', async () => {
  preview('&chat=fail');
  const { stream } = await ask();
  await vi.runAllTimersAsync();
  started.length = 0;
  expect(events).toEqual([
    {
      stream,
      type: 'error',
      message:
        "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.",
    },
  ]);
});

it('has no local API with &chat=no_endpoint, and one that doesn’t answer with &chat=unavailable', async () => {
  preview('&chat=no_endpoint');
  await expect(api.chatModels()).resolves.toEqual({
    models: [],
    code: 'no_endpoint',
    error: 'This Mac’s local API isn’t running.',
  });
  await expect(ask()).rejects.toThrow('isn’t running');
  const withEndpoint = snapshot({
    endpoint: { base_url: 'http://127.0.0.1:8000/v1', authenticated: true, models: [] },
  });
  expect(chatPreview.snapshot!(withEndpoint).endpoint).toBeUndefined();
  preview('&chat=unavailable');
  await expect(api.chatModels()).resolves.toMatchObject({
    models: [],
    code: 'unavailable',
  });
  preview();
  expect(chatPreview.snapshot!(withEndpoint).endpoint).toEqual(withEndpoint.endpoint);
});

it('cuts text into token-sized pieces that put it back together exactly', () => {
  const text = 'Run it:\n\n```bash\ncurl -s "$URL"\n```\n\nThen   done.  ';
  expect(pieces(text).join('')).toBe(text);
  expect(Math.max(...pieces(text).map((piece) => piece.trim().length))).toBeLessThanOrEqual(5);
});
