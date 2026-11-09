// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import {
  chatPreview,
  pieces,
  previewChatAPI,
  previewChatModels,
} from '../src/renderer/preview/chat';
import { reasoningEfforts, type ChatEvent, type ChatRequest } from '../src/shared/chat';
import { snapshot } from './onboardingFixtures';

const events: ChatEvent[] = [];
const started: string[] = [];
let off: () => void;
const ask = (model = 'gpt-oss-20b', extra: Partial<ChatRequest> = {}) =>
  previewChatAPI
    .chatSend({ model, messages: [{ role: 'user', content: 'Hello there' }], ...extra })
    .then((result) => {
      started.push(result.stream);
      return result;
    });
const preview = (query = '') => window.history.replaceState({}, '', `/?preview${query}`);

beforeEach(() => {
  vi.useFakeTimers();
  events.length = 0;
  off = previewChatAPI.onChat((event) => events.push(event));
  preview();
});
afterEach(async () => {
  for (const stream of started.splice(0)) await previewChatAPI.chatCancel(stream);
  off();
  vi.useRealTimers();
});

it('lists development models: this Mac’s, one that reasons with every effort, and your Macs’', async () => {
  const list = await previewChatAPI.chatModels();
  expect(list.code).toBeUndefined();
  expect(list.models).toEqual(previewChatModels);
  expect(list.models.map((model) => [model.id, model.owned_by, model.reasoning])).toEqual([
    ['gpt-oss-20b', 'this-mac', true],
    ['qwen3-vl-30b', 'this-mac', false],
    ['gemma-4-26b', 'my-macs', true],
  ]);
  expect(list.models[0].reasoning_efforts).toEqual([...reasoningEfforts]);
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
  await previewChatAPI.chatCancel(stream);
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
  await expect(previewChatAPI.chatSend({ model: 'gpt-oss-20b', messages: [] })).rejects.toThrow(
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
  await expect(previewChatAPI.chatModels()).resolves.toEqual({
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
  await expect(previewChatAPI.chatModels()).resolves.toMatchObject({
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
