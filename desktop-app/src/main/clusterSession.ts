import { isIPv4, isIPv6 } from 'node:net';
import type { ClusterSession, ClusterSessionAnswer, ClusterSessionStart } from '../shared/cluster';
import type { Backend } from './backend';
import { frameData, splitFrames } from './sse';

// Each frame carries the whole session; a long transcript stays far below this.
const maxBufferedBytes = 4_000_000;
// A stream that says nothing for this long is opened again (any frame or keepalive resets it).
const idleTimeoutMs = 120_000;
const reconnectMs = 250;
const retryMs = 2000;
const maxRetryMs = 30_000;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);

const controlCharacter = /[\u0000-\u001f\u007f]/;

// A model as `darkbloom cluster local <model>` takes it: an id or listed name, never a path or a
// flag.
export const validModel = (model: unknown): model is string =>
  typeof model === 'string' &&
  /^[A-Za-z0-9._/-]{1,256}$/.test(model) &&
  !model.includes('..') &&
  !/^[-/]/.test(model);

// Where the leading Mac's API listens (`--bind`): `localhost` or a numeric IPv4 or IPv6 address,
// as `ClusterServingScope.isValidBind` takes it (no zone index).
export const validBind = (bind: unknown): bind is string =>
  typeof bind === 'string' &&
  bind.length <= 64 &&
  (bind === 'localhost' || isIPv4(bind) || (isIPv6(bind) && !bind.includes('%')));

// The only shapes the renderer may start a session with, rebuilt from their checked fields.
export function sessionStart(value: unknown): ClusterSessionStart {
  if (!isRecord(value)) throw new Error('Invalid cluster setup request');
  const { kind, model, bind, ...rest } = value;
  if (Object.keys(rest).length || (kind !== 'setup' && kind !== 'local'))
    throw new Error('Invalid cluster setup request');
  if (kind === 'setup' && (model !== undefined || bind !== undefined))
    throw new Error('Only a local setup takes a model or an address');
  const start: ClusterSessionStart = { kind };
  if (model !== undefined) {
    if (!validModel(model)) throw new Error('Invalid model');
    start.model = model;
  }
  if (bind !== undefined) {
    if (!validBind(bind)) throw new Error('Invalid address');
    start.bind = bind;
  }
  return start;
}

const validQuestion = (question: unknown): question is string =>
  typeof question === 'string' &&
  question.length > 0 &&
  question.length <= 128 &&
  !controlCharacter.test(question);

// An answer to the question on screen (`choice` or `key`), or `cancel`; nothing else crosses.
export function sessionAnswer(value: unknown): ClusterSessionAnswer {
  if (!isRecord(value)) throw new Error('Invalid answer');
  const keys = Object.keys(value).sort().join(',');
  if (keys === 'cancel' && value.cancel === true) return { cancel: true };
  if (!validQuestion(value.question)) throw new Error('Invalid answer');
  const question = value.question;
  if (keys === 'choice,question') {
    const choice = value.choice;
    if (typeof choice !== 'number' || !Number.isInteger(choice) || choice < 0 || choice > 999)
      throw new Error('Invalid answer');
    return { question, choice };
  }
  if (keys === 'key,question') {
    const key = value.key;
    if (typeof key !== 'string' || key.length < 1 || key.length > 16)
      throw new Error('Invalid answer');
    return { question, key };
  }
  throw new Error('Invalid answer');
}

const sessionKinds = new Set(['setup', 'local']);
const sessionStates = new Set(['running', 'succeeded', 'failed', 'cancelled']);

const isQuestion = (question: unknown) =>
  isRecord(question) &&
  typeof question.id === 'string' &&
  ((question.type === 'choose' &&
    Array.isArray(question.options) &&
    question.options.every(
      (rows) => Array.isArray(rows) && rows.every((row) => typeof row === 'string'),
    ) &&
    typeof question.selected === 'number') ||
    (question.type === 'key' &&
      Array.isArray(question.keys) &&
      question.keys.every(
        (key) => isRecord(key) && typeof key.key === 'string' && typeof key.label === 'string',
      )));

// A session the renderer can read without checking it again. Events it can't show are skipped
// there, one at a time.
export function isClusterSession(value: unknown): value is ClusterSession {
  return (
    isRecord(value) &&
    typeof value.id === 'string' &&
    sessionKinds.has(value.kind as string) &&
    sessionStates.has(value.state as string) &&
    typeof value.started_at === 'number' &&
    Array.isArray(value.events) &&
    value.events.every(isRecord) &&
    (value.question === null || isQuestion(value.question)) &&
    (value.error === undefined || typeof value.error === 'string')
  );
}

function checked(value: unknown): ClusterSession {
  if (!isClusterSession(value)) throw new Error('The cluster setup answered unreadably');
  return value;
}

// One `event: cluster-session` frame's session; undefined for anything else.
export function sessionFrame(frame: string): ClusterSession | undefined {
  if (!frame.split('\n').includes('event: cluster-session')) return undefined;
  const data = frameData(frame);
  if (data === undefined) return undefined;
  try {
    const value: unknown = JSON.parse(data);
    return isClusterSession(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });

// The guided cluster setup session, run by the native API (`/control/v1/cluster/session`). This
// relays the session's routes with checked shapes and holds one event stream while the renderer
// watches it, publishing the whole session on every change.
export class ClusterSessionRelay {
  private subscribers = 0;
  private controller?: AbortController;

  constructor(
    private backend: Backend,
    private publish: (session: ClusterSession) => void,
    private open: (signal: AbortSignal) => Promise<Response> = (signal) =>
      backend.openClusterSessionEvents(signal),
  ) {}

  get active() {
    return !!this.controller;
  }

  // The running or last session; null when none ran since the API started.
  async current(): Promise<ClusterSession | null> {
    const session = await this.backend.request<unknown>('cluster/session');
    return session === null ? null : checked(session);
  }

  async start(start: unknown): Promise<ClusterSession> {
    return checked(await this.backend.request<unknown>('cluster/session', sessionStart(start)));
  }

  async answer(answer: unknown): Promise<ClusterSession> {
    return checked(
      await this.backend.request<unknown>('cluster/session/answer', sessionAnswer(answer)),
    );
  }

  acquire() {
    this.subscribers += 1;
    if (!this.controller) {
      this.controller = new AbortController();
      void this.run(this.controller.signal);
    }
  }

  release() {
    this.subscribers = Math.max(0, this.subscribers - 1);
    if (this.subscribers === 0) this.stop();
  }

  // Drops every subscription, such as when the renderer navigates or crashes.
  reset() {
    this.subscribers = 0;
    this.stop();
  }

  private stop() {
    this.controller?.abort();
    this.controller = undefined;
  }

  private async run(signal: AbortSignal) {
    let failures = 0;
    while (!signal.aborted) {
      const idle = new AbortController();
      let timer: ReturnType<typeof setTimeout> | undefined;
      const touch = () => {
        clearTimeout(timer);
        timer = setTimeout(() => idle.abort(), idleTimeoutMs);
      };
      let delay = reconnectMs;
      try {
        touch();
        const response = await this.open(AbortSignal.any([signal, idle.signal]));
        if (!response.ok || !response.body) throw new Error('Cluster setup stream unavailable');
        failures = 0;
        await this.read(response.body.getReader(), signal, touch);
      } catch {
        // A quiet stream is opened again at once; anything else waits longer each time.
        if (!idle.signal.aborted) {
          failures += 1;
          delay = Math.min(retryMs * 2 ** (failures - 1), maxRetryMs);
        }
      } finally {
        clearTimeout(timer);
      }
      if (!signal.aborted) await sleep(delay, signal);
    }
  }

  private async read(
    reader: ReadableStreamDefaultReader<Uint8Array>,
    signal: AbortSignal,
    touch: () => void,
  ) {
    // The session as it is now, for a change made while no stream was open; a frame that comes
    // first is newer.
    let framed = false;
    this.current().then(
      (session) => {
        if (session && !framed && !signal.aborted) this.publish(session);
      },
      () => {},
    );
    const decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return;
      touch();
      buffer += decoder.decode(value, { stream: true });
      if (buffer.length > maxBufferedBytes) {
        await reader.cancel();
        throw new Error('Cluster setup event too large');
      }
      const { frames, rest } = splitFrames(buffer);
      buffer = rest;
      for (const frame of frames) {
        const session = sessionFrame(frame);
        if (session && !signal.aborted) {
          framed = true;
          this.publish(session);
        }
      }
    }
  }
}
