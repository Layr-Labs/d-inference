import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import type { AddressInfo } from 'node:net';
import {
  ChatRelay,
  apiErrorMessage,
  eventData,
  loopbackBase,
  parseChatData,
  parseModelList,
  type ChatBackend,
} from '../src/main/chat';
import { reasoningEfforts, type ChatEvent, type ChatRequest } from '../src/shared/chat';
import type { Snapshot } from '../src/shared/contracts';
import { snapshot } from './onboardingFixtures';

const KEY = 'dk-local-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const MEMORY =
  "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt (or send less media), or retry when this Mac's other requests finish.";

interface Seen {
  method?: string;
  url?: string;
  headers: IncomingMessage['headers'];
  body: string;
}
let server: Server;
let port: number;
let seen: Seen[];
let closed: number;
let handle: (request: IncomingMessage, response: ServerResponse, body: string) => void;
// Every relay a test made, so none of its streams outlives the test.
const relays: ChatRelay[] = [];

beforeEach(async () => {
  const requests: Seen[] = [];
  seen = requests;
  closed = 0;
  handle = (_, response) => response.writeHead(404).end();
  // A response closed by the previous test's cleanup may report late: count only this server's.
  let ours = true;
  server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => (body += chunk));
    request.on('end', () => {
      requests.push({ method: request.method, url: request.url, headers: request.headers, body });
      handle(request, response, body);
    });
    response.on('close', () => {
      if (ours) closed++;
    });
  });
  server.on('close', () => (ours = false));
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = (server.address() as AddressInfo).port;
});
afterEach(async () => {
  relays.splice(0).forEach((relay) => relay.reset());
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
});

const endpoint = (overrides: Partial<NonNullable<Snapshot['endpoint']>> = {}) => ({
  base_url: `http://127.0.0.1:${port}/v1`,
  authenticated: true,
  models: ['gpt-oss-20b'],
  ...overrides,
});
const backend = (
  value: Snapshot['endpoint'] | undefined = endpoint(),
  read = vi.fn(async () => ({ key: KEY }) as never),
): ChatBackend & { read: typeof read } => ({
  snapshot: snapshot({ endpoint: value }),
  read,
});
const request: ChatRequest = {
  model: 'gpt-oss-20b',
  messages: [{ role: 'user', content: 'Hello' }],
};

function relayWith(
  chatBackend: ChatBackend,
  timeouts = { models: 5_000, head: 5_000, idle: 5_000 },
) {
  const events: ChatEvent[] = [];
  const relay = new ChatRelay(chatBackend, (event) => events.push(event), undefined, timeouts);
  relays.push(relay);
  const finished = (stream: string) =>
    vi.waitFor(
      () => {
        const last = events.filter((event) => event.stream === stream).at(-1);
        if (last?.type !== 'done' && last?.type !== 'error') throw new Error('still streaming');
        return last;
      },
      { timeout: 3_000, interval: 5 },
    );
  return { relay, events, finished };
}

// Frames as the local API writes them (MLXLMServer `ServerSentEventEncoder`).
const frame = (value: unknown) => `data: ${JSON.stringify(value)}\n\n`;
const chunk = (delta: Record<string, unknown>, finish: string | null = null, usage?: unknown) =>
  frame({
    id: 'chatcmpl_1',
    object: 'chat.completion.chunk',
    model: 'gpt-oss-20b',
    choices: [{ index: 0, delta, finish_reason: finish }],
    ...(usage ? { usage } : {}),
  });
const sse = (response: ServerResponse) =>
  response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });

describe('the local API address', () => {
  it.each([
    ['http://127.0.0.1:8000/v1', 'http://127.0.0.1:8000/v1'],
    ['http://localhost:8000/v1/', 'http://localhost:8000/v1'],
    ['http://[::1]:8000/v1', 'http://[::1]:8000/v1'],
  ])('calls %s', (value, base) => {
    expect(loopbackBase(value)).toBe(base);
  });

  it.each([
    'https://127.0.0.1:8000/v1',
    'http://192.168.1.4:8000/v1',
    'http://100.64.0.2:8000/v1',
    'http://example.com/v1',
    'http://127.0.0.1.nip.io:8000/v1',
    'http://user:secret@127.0.0.1:8000/v1',
    'file:///etc/passwd',
    'not a url',
  ])('never calls %s', async (value) => {
    expect(loopbackBase(value)).toBeUndefined();
    const fetcher = vi.fn();
    const chat = backend(endpoint({ base_url: value }));
    const relay = new ChatRelay(chat, () => {}, fetcher);
    await expect(relay.models()).resolves.toMatchObject({ models: [], code: 'unavailable' });
    await expect(relay.send(request)).rejects.toThrow('loopback');
    expect(fetcher).not.toHaveBeenCalled();
    expect(chat.read).not.toHaveBeenCalled();
  });

  it('says there is no local API without calling anything', async () => {
    const fetcher = vi.fn();
    const chat = backend(null as never);
    const relay = new ChatRelay(chat, () => {}, fetcher);
    await expect(relay.models()).resolves.toEqual({
      models: [],
      code: 'no_endpoint',
      error: 'This Mac’s local API isn’t running.',
    });
    await expect(relay.send(request)).rejects.toThrow('isn’t running');
    expect(fetcher).not.toHaveBeenCalled();
    expect(chat.read).not.toHaveBeenCalled();
  });
});

describe('models', () => {
  // The local router's list (`LocalRouterModelEntry`): this Mac's models first, then your Macs'
  // and the network's, with the coordinator's names and features.
  const list = {
    object: 'list',
    data: [
      {
        id: 'gpt-oss-20b',
        object: 'model',
        owned_by: 'this-mac',
        context_length: 131072,
        max_model_len: 131072,
        max_output_length: 131072,
        input_modalities: ['text'],
        supported_features: ['reasoning'],
      },
      {
        id: 'mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit',
        object: 'model',
        owned_by: 'this-mac',
        max_model_len: 262144,
        input_modalities: ['text', 'image'],
        supported_features: [],
      },
      {
        id: 'gemma-4-26b',
        object: 'model',
        owned_by: 'my-macs',
        name: 'Gemma 4 26B',
        supported_features: ['reasoning', 'tools'],
      },
      { id: 'qwen3.8-27b', object: 'model', owned_by: 'darkbloom', name: 'qwen3.8-27b' },
      { id: 'gpt-oss-20b', object: 'model', owned_by: 'my-macs' },
      { object: 'model' },
      'junk',
    ],
  };

  it('lists them with the key, and says which reason and where each runs', async () => {
    handle = (_, response) =>
      response.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(list));
    const chat = backend();
    const { relay } = relayWith(chat);
    const result = await relay.models();
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ method: 'GET', url: '/v1/models' });
    expect(seen[0].headers.authorization).toBe(`Bearer ${KEY}`);
    expect(chat.read).toHaveBeenCalledExactlyOnceWith('endpoint-key');
    expect(result.base_url).toBe(`http://127.0.0.1:${port}/v1`);
    expect(result.code).toBeUndefined();
    expect(result.models).toEqual([
      {
        id: 'gpt-oss-20b',
        name: 'GPT-OSS 20B',
        owned_by: 'this-mac',
        reasoning: true,
        reasoning_efforts: [...reasoningEfforts],
        context_length: 131072,
        max_output_length: 131072,
        input_modalities: ['text'],
      },
      {
        id: 'mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit',
        name: null,
        owned_by: 'this-mac',
        reasoning: false,
        reasoning_efforts: null,
        context_length: 262144,
        max_output_length: null,
        input_modalities: ['text', 'image'],
      },
      {
        id: 'gemma-4-26b',
        name: 'Gemma 4 26B',
        owned_by: 'my-macs',
        reasoning: true,
        reasoning_efforts: [...reasoningEfforts],
        context_length: null,
        max_output_length: null,
        input_modalities: null,
      },
      {
        id: 'qwen3.8-27b',
        name: null,
        owned_by: 'darkbloom',
        reasoning: null,
        reasoning_efforts: null,
        context_length: null,
        max_output_length: null,
        input_modalities: null,
      },
    ]);
  });

  it('never reads the key for a local API that takes none', async () => {
    handle = (_, response) => response.writeHead(200).end(JSON.stringify({ data: [] }));
    const chat = backend(endpoint({ authenticated: false }));
    await expect(relayWith(chat).relay.models()).resolves.toMatchObject({ models: [] });
    expect(chat.read).not.toHaveBeenCalled();
    expect(seen[0].headers.authorization).toBeUndefined();
  });

  it('shows the local API’s own refusal', async () => {
    handle = (_, response) =>
      response
        .writeHead(401, { 'Content-Type': 'application/json' })
        .end(
          '{"error":{"message":"missing or invalid local API key — get it from `darkbloom local`","type":"authentication_error"}}',
        );
    await expect(relayWith(backend()).relay.models()).resolves.toMatchObject({
      models: [],
      code: 'unavailable',
      error: 'missing or invalid local API key — get it from `darkbloom local`',
    });
  });

  it('gives up on a local API that doesn’t answer in time', async () => {
    handle = () => {};
    const { relay } = relayWith(backend(), { models: 60, head: 5_000, idle: 5_000 });
    await expect(relay.models()).resolves.toMatchObject({
      code: 'unavailable',
      error: 'This Mac’s local API didn’t answer.',
    });
  });

  it('says so when the key can’t be read, without calling the local API', async () => {
    const chat = backend(
      endpoint(),
      vi.fn(async () => {
        throw new Error('Runtime is not connected');
      }),
    );
    await expect(relayWith(chat).relay.models()).resolves.toMatchObject({
      code: 'unavailable',
      error: 'Couldn’t read this Mac’s local API key.',
    });
    expect(seen).toHaveLength(0);
  });
});

describe('send', () => {
  it('streams reasoning, then the answer, then how it finished', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ role: 'assistant' }));
      // Each piece of reasoning arrives twice, as `reasoning` and `reasoning_content`.
      response.write(chunk({ reasoning: 'Let me ', reasoning_content: 'Let me ' }));
      // A frame split across writes, and a keepalive comment.
      const split = chunk({ reasoning: 'think.', reasoning_content: 'think.' });
      response.write(split.slice(0, 20));
      setTimeout(() => {
        response.write(split.slice(20) + ': keepalive\n\n');
        response.write(chunk({ content: 'Hello' }).replace(/\n/g, '\r\n'));
        response.write(chunk({ content: ' there.' }));
        response.write(
          chunk({}, 'stop', { prompt_tokens: 12, completion_tokens: 9, total_tokens: 21 }),
        );
        response.end('data: [DONE]\n\n');
      }, 20);
    };
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send({
      ...request,
      reasoning_effort: 'high',
      extra: 'dropped',
    } as ChatRequest);
    expect(events).toEqual([]);
    await finished(stream);
    expect(events).toEqual([
      { stream, type: 'reasoning', text: 'Let me ' },
      { stream, type: 'reasoning', text: 'think.' },
      { stream, type: 'content', text: 'Hello' },
      { stream, type: 'content', text: ' there.' },
      {
        stream,
        type: 'done',
        finish_reason: 'stop',
        usage: { prompt_tokens: 12, completion_tokens: 9 },
      },
    ]);
    expect(seen[0]).toMatchObject({ method: 'POST', url: '/v1/chat/completions' });
    expect(seen[0].headers.authorization).toBe(`Bearer ${KEY}`);
    expect(seen[0].headers['content-type']).toBe('application/json');
    expect(JSON.parse(seen[0].body)).toEqual({
      model: 'gpt-oss-20b',
      messages: [{ role: 'user', content: 'Hello' }],
      stream: true,
      stream_options: { include_usage: true },
      reasoning_effort: 'high',
    });
  });

  it('ends a refused request with the local API’s own message, such as a busy Mac', async () => {
    handle = (_, response) =>
      response
        .writeHead(503, { 'Content-Type': 'application/json' })
        .end(JSON.stringify({ error: { message: MEMORY, type: 'invalid_request_error' } }));
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events).toEqual([{ stream, type: 'error', message: MEMORY }]);
  });

  it('says the status when the local API gives no message', async () => {
    handle = (_, response) => response.writeHead(502).end('<html>Bad gateway</html>');
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events).toEqual([
      { stream, type: 'error', message: 'This Mac’s local API answered 502.' },
    ]);
  });

  it('ends with the failure frame the local API sends mid-answer', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Partial' }));
      response.end(
        frame({
          id: 'chatcmpl_1',
          choices: [{ index: 0, delta: { content: '' }, finish_reason: 'error' }],
          error: { message: 'Response generation failed', type: 'server_error', code: null },
        }),
      );
    };
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events).toEqual([
      { stream, type: 'content', text: 'Partial' },
      { stream, type: 'error', message: 'Response generation failed' },
    ]);
  });

  it('says so when the answer stops before it finishes', async () => {
    handle = (_, response) => {
      sse(response);
      response.end(chunk({ content: 'Half an' }));
    };
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events.at(-1)).toEqual({
      stream,
      type: 'error',
      message: 'The answer stopped before it finished.',
    });
  });

  it('keeps an answer that said how it finished, even without [DONE]', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Done.' }));
      response.end(chunk({}, 'length'));
    };
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events.at(-1)).toEqual({ stream, type: 'done', finish_reason: 'length', usage: null });
  });

  it('stops an answer on cancel, closing the request', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Thinking about it' }));
    };
    const { relay, events, finished } = relayWith(backend());
    const { stream } = await relay.send(request);
    await vi.waitFor(() => expect(events).toHaveLength(1));
    await relay.cancel(stream);
    await finished(stream);
    expect(events.at(-1)).toEqual({
      stream,
      type: 'done',
      finish_reason: 'cancelled',
      usage: null,
    });
    await vi.waitFor(() => expect(closed).toBe(1));
    await relay.cancel(stream);
    await relay.cancel(42);
    expect(events).toHaveLength(2);
  });

  it('streams at most two answers at once', async () => {
    handle = (_, response) => sse(response);
    const { relay, finished } = relayWith(backend());
    const first = await relay.send(request);
    await relay.send(request);
    await expect(relay.send(request)).rejects.toThrow(
      'Two answers are already streaming. Wait for one to finish.',
    );
    await relay.cancel(first.stream);
    await finished(first.stream);
    await expect(relay.send(request)).resolves.toHaveProperty('stream');
  });

  it('ends every stream without another event on reset', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Still going' }));
    };
    const { relay, events } = relayWith(backend());
    await relay.send(request);
    await relay.send(request);
    await vi.waitFor(() => expect(events).toHaveLength(2));
    relay.reset();
    await vi.waitFor(() => expect(closed).toBe(2));
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(events.map((event) => event.type)).toEqual(['content', 'content']);
    await expect(relay.send(request)).resolves.toHaveProperty('stream');
  });

  it('gives up on a stream that goes quiet', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Then nothing' }));
    };
    const { relay, events, finished } = relayWith(backend(), {
      models: 5_000,
      head: 5_000,
      idle: 60,
    });
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events.at(-1)).toEqual({
      stream,
      type: 'error',
      message: 'This Mac’s local API stopped answering.',
    });
  });

  it('says so when this Mac’s local API isn’t listening', async () => {
    const free = port;
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    server = createServer();
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const { relay, events, finished } = relayWith(
      backend(endpoint({ base_url: `http://127.0.0.1:${free}/v1` })),
    );
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events).toEqual([
      { stream, type: 'error', message: 'This Mac’s local API didn’t answer.' },
    ]);
  });

  it.each<[string, unknown, string]>([
    ['no model', { ...request, model: '' }, 'Choose a model.'],
    ['a model with a newline', { ...request, model: 'a\nb' }, 'Choose a model.'],
    ['no messages', { ...request, messages: [] }, 'Write a message first.'],
    [
      'more than 200 messages',
      { ...request, messages: Array.from({ length: 201 }, () => request.messages[0]) },
      'This chat is too long to send. Start a new chat.',
    ],
    [
      'more than 400,000 characters',
      { ...request, messages: [{ role: 'user', content: 'x'.repeat(400_001) }] },
      'This chat is too long to send. Start a new chat.',
    ],
    [
      'a role the API has no use for',
      { ...request, messages: [{ role: 'tool', content: 'x' }] },
      'Invalid chat request.',
    ],
    [
      'an effort that is none of the seven',
      { ...request, reasoning_effort: 'turbo' },
      'Choose a reasoning effort this Mac takes.',
    ],
    ['not an object', 'hello', 'Invalid chat request.'],
  ])('refuses %s before calling anything', async (_, value, message) => {
    const fetcher = vi.fn();
    const chat = backend();
    const relay = new ChatRelay(chat, () => {}, fetcher);
    await expect(relay.send(value)).rejects.toThrow(message);
    expect(fetcher).not.toHaveBeenCalled();
    expect(chat.read).not.toHaveBeenCalled();
  });

  it('accepts exactly 200 messages and 400,000 characters', async () => {
    handle = (_, response) => {
      sse(response);
      response.end('data: [DONE]\n\n');
    };
    const { relay, finished } = relayWith(backend());
    const messages = Array.from({ length: 200 }, (_, index) => ({
      role: 'user' as const,
      content: index ? '' : 'x'.repeat(400_000),
    }));
    const { stream } = await relay.send({ ...request, messages });
    await finished(stream);
    expect(JSON.parse(seen[0].body).messages).toHaveLength(200);
  });

  it('never lets the key reach an event or a result', async () => {
    handle = (_, response) => {
      sse(response);
      response.write(chunk({ content: 'Fine.' }));
      response.end('data: [DONE]\n\n');
    };
    const { relay, events, finished } = relayWith(backend());
    const result = await relay.send(request);
    await finished(result.stream);
    const models = await relay.models();
    expect(JSON.stringify([events, result, models])).not.toContain(KEY);
    expect(JSON.stringify([events, result, models])).not.toContain('dk-local');
  });

  it('ends with a plain error when the key can’t be read', async () => {
    const chat = backend(
      endpoint(),
      vi.fn(async () => ({ key: 'bad key\r\nInjected: 1' }) as never),
    );
    const { relay, events, finished } = relayWith(chat);
    const { stream } = await relay.send(request);
    await finished(stream);
    expect(events).toEqual([
      { stream, type: 'error', message: 'Couldn’t read this Mac’s local API key.' },
    ]);
    expect(seen).toHaveLength(0);
  });
});

describe('parsing', () => {
  it('reads each event’s data, with or without a space, across lines', () => {
    expect(eventData('data: {"a":1}')).toBe('{"a":1}');
    expect(eventData('event: message\ndata:{"a":1}')).toBe('{"a":1}');
    expect(eventData('data: one\ndata: two')).toBe('one\ntwo');
    expect(eventData(': keepalive')).toBeUndefined();
  });

  it('reads one chunk’s reasoning, answer, finish and usage', () => {
    expect(parseChatData('[DONE]')).toEqual({ done: true });
    expect(parseChatData('not json')).toEqual({});
    expect(
      parseChatData(
        JSON.stringify({
          choices: [
            {
              delta: { reasoning_content: 'Why', reasoning: 'Why', content: '' },
              finish_reason: null,
            },
          ],
        }),
      ),
    ).toEqual({ reasoning: 'Why' });
    expect(parseChatData(JSON.stringify({ choices: [{ delta: { reasoning: 'Only' } }] }))).toEqual({
      reasoning: 'Only',
    });
    expect(
      parseChatData(
        JSON.stringify({
          choices: [{ delta: {}, finish_reason: 'stop' }],
          usage: { prompt_tokens: 3, completion_tokens: 4, total_tokens: 7 },
        }),
      ),
    ).toEqual({ finish: 'stop', usage: { prompt_tokens: 3, completion_tokens: 4 } });
    expect(parseChatData(JSON.stringify({ error: { message: 'Over \u0007capacity' } }))).toEqual({
      error: 'Over capacity',
    });
    expect(parseChatData(JSON.stringify({ error: {} }))).toEqual({ error: 'The answer failed.' });
  });

  it('keeps the list’s own names, else this Mac’s, and refuses a list without data', () => {
    expect(() => parseModelList({ models: [] })).toThrow('sent no model list');
    expect(
      parseModelList(
        {
          data: [
            { id: 'a', name: 'a' },
            { id: 'b', name: 'Bee' },
          ],
        },
        [{ ...snapshot().models[0], id: 'a', display_name: 'Ay' }],
      ).map((model) => model.name),
    ).toEqual(['Ay', 'Bee']);
  });

  it('words an error without a message by its status', () => {
    expect(apiErrorMessage('', 401)).toBe('This Mac’s local API didn’t accept its key.');
    expect(apiErrorMessage('{"error":"Plain words"}', 500)).toBe('Plain words');
    expect(apiErrorMessage('{"message":"Top level"}', 500)).toBe('Top level');
    expect(apiErrorMessage('{}', 429)).toBe('This Mac’s local API answered 429.');
  });
});
