import { randomUUID } from 'node:crypto';
import {
  reasoningEfforts,
  validateChatRequest,
  type ChatEvent,
  type ChatModel,
  type ChatModels,
  type ChatRequest,
} from '../shared/chat';
import type { NativeModel, Snapshot } from '../shared/contracts';
import { splitFrames } from './sse';

// Chat with this Mac's local API. The main process holds the local API key and makes every
// request, so the renderer never sees it; only a loopback base URL from the native snapshot is
// ever called. Each streamed answer is published as ChatEvents tagged with its stream ID.

// What the relay reads from Backend: the live snapshot (`endpoint`, and this Mac's model names)
// and the local API key (`GET /control/v1/endpoint-key`, `{ key }`).
export interface ChatBackend {
  readonly snapshot?: Snapshot;
  read<T>(resource: 'endpoint-key'): Promise<T>;
}

type Fetch = (url: string, init: RequestInit) => Promise<Response>;
type Usage = { prompt_tokens?: number; completion_tokens?: number };

// How long each step may take. A streamed answer's head waits while a cold model loads, and on a
// busy Mac through the engine's 120 s admission lease (docs/provider/direct-mode.md#routes).
export interface ChatTimeouts {
  models: number;
  head: number;
  idle: number;
}
const defaultTimeouts: ChatTimeouts = { models: 5_000, head: 10 * 60_000, idle: 5 * 60_000 };
const maxStreams = 2;
const maxListBytes = 2_000_000;
const maxErrorBytes = 64_000;
const maxFrameCharacters = 1_000_000;
const maxAnswerCharacters = 4_000_000;
const maxModels = 500;
const loopbackHosts = new Set(['127.0.0.1', 'localhost', '[::1]']);

const notRunning = 'This Mac’s local API isn’t running.';
const notLoopback = 'Chat calls this Mac’s local API only on this Mac’s loopback address.';
const noAnswer = 'This Mac’s local API didn’t answer.';
const keyUnreadable = 'Couldn’t read this Mac’s local API key.';
const stoppedEarly = 'The answer stopped before it finished.';
const stalled = 'This Mac’s local API stopped answering.';
const tooMany = 'Two answers are already streaming. Wait for one to finish.';
const tooLong = 'This answer is too long to show.';

// A failure whose message is meant for the person.
class ChatFailure extends Error {}

// The base URL to call, without a trailing slash, or undefined for anything that isn't plain
// http on this Mac's loopback address (`127.0.0.1`, `localhost`, `[::1]`).
export function loopbackBase(value: unknown): string | undefined {
  if (typeof value !== 'string' || value.length > 2048) return undefined;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if (url.protocol !== 'http:' || !loopbackHosts.has(url.hostname)) return undefined;
  if (url.username || url.password) return undefined;
  return `${url.origin}${url.pathname.replace(/\/+$/, '')}`;
}

// Text from the local API for the person: no control characters, bounded.
const plain = (text: string) =>
  text
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
    .trim()
    .slice(0, 600);

// The local API's own message from its OpenAI error envelope (`{"error": {"message"}}`), such as
// the 503 when this Mac's memory can't hold a request now; else the status in plain words.
export function apiErrorMessage(body: string, status: number): string {
  try {
    const value = JSON.parse(body) as { error?: unknown; message?: unknown } | null;
    const error = value?.error;
    const message =
      typeof error === 'string'
        ? error
        : error && typeof error === 'object'
          ? (error as { message?: unknown }).message
          : value?.message;
    if (typeof message === 'string' && plain(message)) return plain(message);
  } catch {}
  if (status === 401) return 'This Mac’s local API didn’t accept its key.';
  return `This Mac’s local API answered ${status}.`;
}

const text = (value: unknown, limit: number) =>
  typeof value === 'string' && value.trim() && value.length <= limit ? value : undefined;
const positive = (value: unknown) =>
  typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined;
const strings = (value: unknown) =>
  Array.isArray(value)
    ? value.filter((item): item is string => typeof item === 'string' && item.length <= 64)
    : undefined;
const count = (value: unknown) =>
  typeof value === 'number' && Number.isFinite(value) && value >= 0 ? Math.round(value) : undefined;

// The local API's model list as ChatModels: `supported_features` says which reason (each of those
// takes every reasoning effort), `owned_by` where each runs. This Mac's own names fill in a model
// the list doesn't name.
export function parseModelList(value: unknown, known: NativeModel[] = []): ChatModel[] {
  const data = (value as { data?: unknown } | null)?.data;
  if (!Array.isArray(data)) throw new ChatFailure('This Mac’s local API sent no model list.');
  const names = new Map(known.map((model) => [model.id, model.display_name]));
  const seen = new Set<string>();
  const models: ChatModel[] = [];
  for (const entry of data.slice(0, maxModels)) {
    if (!entry || typeof entry !== 'object') continue;
    const item = entry as Record<string, unknown>;
    const id = text(item.id, 256);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    const features = strings(item.supported_features);
    const reasoning = features
      ? features.some((feature) => feature.toLowerCase() === 'reasoning')
      : null;
    const listed = text(item.name, 200);
    models.push({
      id,
      name: (listed !== id ? listed : undefined) ?? text(names.get(id), 200) ?? null,
      owned_by: text(item.owned_by, 40) ?? null,
      reasoning,
      reasoning_efforts: reasoning ? [...reasoningEfforts] : null,
      context_length: positive(item.context_length) ?? positive(item.max_model_len) ?? null,
      max_output_length: positive(item.max_output_length) ?? null,
      input_modalities: strings(item.input_modalities) ?? null,
    });
  }
  return models;
}

// One server-sent event's data (its `data:` lines joined), or undefined for a frame without data,
// such as a keepalive comment.
export function eventData(frame: string): string | undefined {
  let data: string[] | undefined;
  for (const line of frame.split('\n')) {
    if (!line.startsWith('data:')) continue;
    (data ??= []).push(line.slice(line.startsWith('data: ') ? 6 : 5));
  }
  return data?.join('\n');
}

export interface ChatChunk {
  reasoning?: string;
  content?: string;
  finish?: string;
  usage?: Usage;
  error?: string;
  done?: boolean;
}

const nonEmpty = (value: unknown) => (typeof value === 'string' && value ? value : undefined);

// One streamed chat completion chunk. The local API sends each piece of reasoning twice, as
// `reasoning_content` and `reasoning` (the same text, for clients that read either); one is used.
// A failure mid-answer arrives as a chunk with `error` (MLXLMServer `ChatStreamFailure`).
export function parseChatData(data: string): ChatChunk {
  if (data.trim() === '[DONE]') return { done: true };
  let value: Record<string, unknown>;
  try {
    value = JSON.parse(data);
  } catch {
    return {};
  }
  if (!value || typeof value !== 'object') return {};
  const chunk: ChatChunk = {};
  if (value.error) {
    const error = value.error as { message?: unknown } | string;
    const message = typeof error === 'string' ? error : error.message;
    chunk.error =
      typeof message === 'string' && plain(message) ? plain(message) : 'The answer failed.';
  }
  const choice = (Array.isArray(value.choices) ? value.choices[0] : undefined) as
    { delta?: Record<string, unknown>; finish_reason?: unknown } | undefined;
  const delta = choice?.delta;
  if (delta && typeof delta === 'object') {
    const reasoning = nonEmpty(delta.reasoning_content) ?? nonEmpty(delta.reasoning);
    if (reasoning) chunk.reasoning = reasoning;
    const content = nonEmpty(delta.content);
    if (content) chunk.content = content;
  }
  if (typeof choice?.finish_reason === 'string') chunk.finish = choice.finish_reason;
  const usage = value.usage as Record<string, unknown> | null | undefined;
  if (usage && typeof usage === 'object')
    chunk.usage = {
      prompt_tokens: count(usage.prompt_tokens),
      completion_tokens: count(usage.completion_tokens),
    };
  return chunk;
}

// Reads a response body up to `limit` bytes: an error body is cut there, a list refused past it.
async function readText(response: Response, limit: number, cut = false): Promise<string> {
  if (!response.body) return '';
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let result = '';
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel().catch(() => {});
      if (cut) break;
      throw new ChatFailure('This Mac’s local API sent too much.');
    }
    result += decoder.decode(value, { stream: true });
  }
  return result + decoder.decode();
}

// One streamed request: its abort and why it ended early, and one timer for how long it may wait.
class Stream {
  readonly controller = new AbortController();
  reason?: 'cancel' | 'reset' | 'timeout';
  ended = false;
  private timer?: ReturnType<typeof setTimeout>;
  arm(ms: number) {
    this.disarm();
    this.timer = setTimeout(() => this.abort('timeout'), ms);
  }
  disarm() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
  }
  abort(reason: 'cancel' | 'reset' | 'timeout') {
    this.reason ??= reason;
    this.controller.abort();
  }
}

export class ChatRelay {
  private streams = new Map<string, Stream>();

  constructor(
    private backend: ChatBackend,
    private publish: (event: ChatEvent) => void,
    private fetcher: Fetch = (url, init) => fetch(url, init),
    private timeouts: ChatTimeouts = defaultTimeouts,
  ) {}

  // The models this Mac's local API lists, or why there are none to chat with.
  async models(): Promise<ChatModels> {
    const endpoint = this.backend.snapshot?.endpoint;
    if (!endpoint) return { models: [], code: 'no_endpoint', error: notRunning };
    const base = loopbackBase(endpoint.base_url);
    if (!base) return { models: [], code: 'unavailable', error: notLoopback };
    try {
      const headers = await this.headers(endpoint.authenticated);
      const response = await this.fetcher(`${base}/models`, {
        headers: { ...headers, Accept: 'application/json' },
        redirect: 'error',
        signal: AbortSignal.timeout(this.timeouts.models),
      });
      if (!response.ok) {
        const body = await readText(response, maxErrorBytes, true).catch(() => '');
        return {
          base_url: base,
          models: [],
          code: 'unavailable',
          error: apiErrorMessage(body, response.status),
        };
      }
      const list = JSON.parse(await readText(response, maxListBytes));
      return { base_url: base, models: parseModelList(list, this.backend.snapshot?.models) };
    } catch (error) {
      return {
        base_url: base,
        models: [],
        code: 'unavailable',
        error: error instanceof ChatFailure ? error.message : noAnswer,
      };
    }
  }

  // Starts one streamed answer and returns its ID at once; its events follow through `publish`.
  async send(value: unknown): Promise<{ stream: string }> {
    const request: ChatRequest = validateChatRequest(value);
    const endpoint = this.backend.snapshot?.endpoint;
    if (!endpoint) throw new Error(notRunning);
    const base = loopbackBase(endpoint.base_url);
    if (!base) throw new Error(notLoopback);
    if (this.streams.size >= maxStreams) throw new Error(tooMany);
    const id = randomUUID();
    const stream = new Stream();
    this.streams.set(id, stream);
    const body = {
      model: request.model,
      messages: request.messages,
      stream: true,
      stream_options: { include_usage: true },
      ...(request.reasoning_effort ? { reasoning_effort: request.reasoning_effort } : {}),
      ...(request.max_tokens ? { max_tokens: request.max_tokens } : {}),
      ...(request.temperature !== undefined ? { temperature: request.temperature } : {}),
    };
    // Begins after this call returns, so the renderer has the stream ID before its first event.
    setTimeout(() => void this.run(id, stream, base, endpoint.authenticated, body), 0);
    return { stream: id };
  }

  // Stops one answer; it ends with `done` and `finish_reason: 'cancelled'`.
  async cancel(id: unknown) {
    if (typeof id === 'string') this.streams.get(id)?.abort('cancel');
  }

  // Ends every stream without another event, such as when the window navigates or closes.
  reset() {
    for (const stream of this.streams.values()) stream.abort('reset');
    this.streams.clear();
  }

  private async headers(authenticated: boolean): Promise<Record<string, string>> {
    if (!authenticated) return {};
    let value: unknown;
    try {
      value = await this.backend.read<unknown>('endpoint-key');
    } catch {
      throw new ChatFailure(keyUnreadable);
    }
    const key = (value as { key?: unknown } | null)?.key;
    if (typeof key !== 'string' || !/^[\x21-\x7e]{1,4096}$/.test(key))
      throw new ChatFailure(keyUnreadable);
    return { Authorization: `Bearer ${key}` };
  }

  private end(stream: Stream, event: ChatEvent) {
    if (stream.ended || stream.reason === 'reset') return;
    stream.ended = true;
    this.publish(event);
  }

  private async run(
    id: string,
    stream: Stream,
    base: string,
    authenticated: boolean,
    body: Record<string, unknown>,
  ) {
    let finish: string | null = null;
    let usage: Usage | null = null;
    let characters = 0;
    const emit = (event: ChatEvent) => {
      if (!stream.ended && stream.reason !== 'reset') this.publish(event);
    };
    try {
      const headers = await this.headers(authenticated);
      stream.arm(this.timeouts.head);
      const response = await this.fetcher(`${base}/chat/completions`, {
        method: 'POST',
        redirect: 'error',
        signal: stream.controller.signal,
        headers: { ...headers, 'Content-Type': 'application/json', Accept: 'text/event-stream' },
        body: JSON.stringify(body),
      });
      if (!response.ok) {
        const text = await readText(response, maxErrorBytes, true).catch(() => '');
        return this.end(stream, {
          stream: id,
          type: 'error',
          message: apiErrorMessage(text, response.status),
        });
      }
      if (!response.body) throw new ChatFailure(noAnswer);
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      for (;;) {
        stream.arm(this.timeouts.idle);
        const { value, done } = await reader.read();
        if (done) break;
        buffer = (buffer + decoder.decode(value, { stream: true })).replace(/\r\n/g, '\n');
        if (buffer.length > maxFrameCharacters) {
          await reader.cancel().catch(() => {});
          throw new ChatFailure(stoppedEarly);
        }
        const { frames, rest } = splitFrames(buffer);
        buffer = rest;
        for (const frame of frames) {
          const data = eventData(frame);
          if (data === undefined) continue;
          const chunk = parseChatData(data);
          if (chunk.reasoning) {
            characters += chunk.reasoning.length;
            emit({ stream: id, type: 'reasoning', text: chunk.reasoning });
          }
          if (chunk.content) {
            characters += chunk.content.length;
            emit({ stream: id, type: 'content', text: chunk.content });
          }
          if (chunk.finish) finish = chunk.finish;
          if (chunk.usage) usage = chunk.usage;
          const last: ChatEvent | undefined = chunk.error
            ? { stream: id, type: 'error', message: chunk.error }
            : chunk.done
              ? { stream: id, type: 'done', finish_reason: finish, usage }
              : characters > maxAnswerCharacters
                ? { stream: id, type: 'error', message: tooLong }
                : undefined;
          if (last) {
            await reader.cancel().catch(() => {});
            return this.end(stream, last);
          }
        }
      }
      // Closed without `[DONE]`: an answer that said how it finished is still complete.
      this.end(
        stream,
        finish
          ? { stream: id, type: 'done', finish_reason: finish, usage }
          : { stream: id, type: 'error', message: stoppedEarly },
      );
    } catch (error) {
      if (stream.reason === 'cancel')
        return this.end(stream, { stream: id, type: 'done', finish_reason: 'cancelled', usage });
      if (stream.reason === 'timeout')
        return this.end(stream, { stream: id, type: 'error', message: stalled });
      this.end(stream, {
        stream: id,
        type: 'error',
        message: error instanceof ChatFailure ? error.message : noAnswer,
      });
    } finally {
      stream.disarm();
      if (this.streams.get(id) === stream) this.streams.delete(id);
    }
  }
}

export type { ChatRequest };
