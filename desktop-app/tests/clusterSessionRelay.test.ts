import { describe, expect, it, vi } from 'vitest';
import type { Backend } from '../src/main/backend';
import {
  ClusterSessionRelay,
  isClusterSession,
  sessionAnswer,
  sessionFrame,
  sessionStart,
} from '../src/main/clusterSession';
import type { ClusterSession } from '../src/shared/cluster';

const session = (patch: Partial<ClusterSession> = {}): ClusterSession => ({
  id: 'session-1',
  kind: 'setup',
  state: 'running',
  started_at: 1_790_000_000,
  events: [{ type: 'banner', title: 'Darkbloom cluster', subtitle: '' }],
  question: null,
  ...patch,
});
const frame = (value: unknown, event = 'cluster-session') =>
  `event: ${event}\ndata: ${JSON.stringify(value)}\n\n`;

// A live SSE body the test writes into, like the runtime's chunked response.
function stream() {
  let controller!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start: (c) => (controller = c) });
  const encoder = new TextEncoder();
  return {
    response: new Response(body, { headers: { 'Content-Type': 'text/event-stream' } }),
    write: (text: string) => controller.enqueue(encoder.encode(text)),
    close: () => controller.close(),
  };
}

// The main process's Backend, reduced to the request the relay makes.
function backendWith(request: (resource: string, body?: unknown) => Promise<unknown>) {
  return { request: vi.fn(request) } as unknown as Backend & {
    request: ReturnType<typeof vi.fn>;
  };
}

describe('starting a setup', () => {
  it('passes the two kinds, with a model and an address only for local serving', () => {
    expect(sessionStart({ kind: 'setup' })).toEqual({ kind: 'setup' });
    expect(sessionStart({ kind: 'local' })).toEqual({ kind: 'local' });
    expect(sessionStart({ kind: 'local', model: 'glm-5.3-flash', bind: '127.0.0.1' })).toEqual({
      kind: 'local',
      model: 'glm-5.3-flash',
      bind: '127.0.0.1',
    });
    for (const bind of ['localhost', '0.0.0.0', '::1', '100.64.0.9', 'fd7a:115c:a1e0::1'])
      expect(sessionStart({ kind: 'local', bind }).bind).toBe(bind);
    expect(sessionStart({ kind: 'local', model: 'mlx-community/Qwen3.8-27B-4bit' }).model).toBe(
      'mlx-community/Qwen3.8-27B-4bit',
    );
  });

  it('refuses anything that could become a flag, a path or a host name', () => {
    const refused = [
      null,
      'setup',
      [],
      { kind: 'cluster' },
      { kind: 'setup', model: 'glm-5.3-flash' },
      { kind: 'setup', bind: '127.0.0.1' },
      { kind: 'local', model: '--worker' },
      { kind: 'local', model: '/etc/passwd' },
      { kind: 'local', model: 'a/../b' },
      { kind: 'local', model: 'two words' },
      { kind: 'local', model: '' },
      { kind: 'local', model: 'x'.repeat(257) },
      { kind: 'local', model: 7 },
      { kind: 'local', bind: 'example.com' },
      { kind: 'local', bind: '1.2.3' },
      { kind: 'local', bind: '01.2.3.4' },
      { kind: 'local', bind: 'fe80::1%en0' },
      { kind: 'local', bind: '' },
      { kind: 'local', extra: true },
    ];
    for (const value of refused) expect(() => sessionStart(value), JSON.stringify(value)).toThrow();
  });
});

describe('answering', () => {
  it('passes a choice, a key or cancel, rebuilt from their own fields', () => {
    expect(sessionAnswer({ question: 'q-1', choice: 2 })).toEqual({ question: 'q-1', choice: 2 });
    expect(sessionAnswer({ question: 'q-1', key: 'q' })).toEqual({ question: 'q-1', key: 'q' });
    expect(sessionAnswer({ cancel: true })).toEqual({ cancel: true });
  });

  it('refuses malformed answers', () => {
    const refused = [
      undefined,
      { cancel: false },
      { cancel: 'yes' },
      { cancel: true, question: 'q-1' },
      { question: 'q-1' },
      { question: 'q-1', choice: -1 },
      { question: 'q-1', choice: 1.5 },
      { question: 'q-1', choice: '1' },
      { question: 'q-1', choice: 1, key: 'q' },
      { question: 'q-1', key: '' },
      { question: 'q-1', key: 'x'.repeat(17) },
      { question: '', choice: 0 },
      { question: 'q\n1', choice: 0 },
      { question: 'x'.repeat(129), choice: 0 },
    ];
    for (const value of refused)
      expect(() => sessionAnswer(value), JSON.stringify(value)).toThrow();
  });
});

describe('session frames', () => {
  it('reads only cluster-session events holding a readable session', () => {
    expect(sessionFrame(frame(session()).trim())).toEqual(session());
    expect(sessionFrame(frame(session(), 'state').trim())).toBeUndefined();
    expect(sessionFrame('event: cluster-session\ndata: {not json')).toBeUndefined();
    expect(sessionFrame(frame({ ...session(), state: 'paused' }).trim())).toBeUndefined();
    expect(sessionFrame(frame({ ...session(), events: [7] }).trim())).toBeUndefined();
    expect(sessionFrame(': keepalive')).toBeUndefined();
  });

  it('checks the question it carries', () => {
    const choose = { id: 'q', type: 'choose', options: [['Yes'], ['No']], selected: 0 };
    expect(isClusterSession(session({ question: choose as never }))).toBe(true);
    expect(
      isClusterSession(session({ question: { id: 'k', type: 'key', keys: [] } as never })),
    ).toBe(true);
    expect(
      isClusterSession(session({ question: { ...choose, options: [['Yes', 1]] } as never })),
    ).toBe(false);
    expect(isClusterSession(session({ question: { id: 'k', type: 'type' } as never }))).toBe(false);
  });
});

describe('ClusterSessionRelay', () => {
  it('calls the session routes with checked bodies and checks what comes back', async () => {
    const backend = backendWith(async (resource) =>
      resource === 'cluster/session/answer' ? session({ question: null }) : session(),
    );
    const relay = new ClusterSessionRelay(backend, () => {});
    await expect(relay.start({ kind: 'local', model: 'glm-5.3-flash' })).resolves.toEqual(
      session(),
    );
    expect(backend.request).toHaveBeenLastCalledWith('cluster/session', {
      kind: 'local',
      model: 'glm-5.3-flash',
    });
    await relay.answer({ question: 'q-1', choice: 1 });
    expect(backend.request).toHaveBeenLastCalledWith('cluster/session/answer', {
      question: 'q-1',
      choice: 1,
    });
    await relay.current();
    expect(backend.request).toHaveBeenLastCalledWith('cluster/session');
    expect(backend.request).toHaveBeenCalledTimes(3);
  });

  it('sends nothing for a refused start or answer', async () => {
    const backend = backendWith(async () => session());
    const relay = new ClusterSessionRelay(backend, () => {});
    await expect(relay.start({ kind: 'local', model: '--help' })).rejects.toThrow('Invalid model');
    await expect(relay.answer({ question: 'q', choice: -1 })).rejects.toThrow('Invalid answer');
    expect(backend.request).not.toHaveBeenCalled();
  });

  it('reads no session as null and refuses an unreadable one', async () => {
    let answer: unknown = null;
    const relay = new ClusterSessionRelay(
      backendWith(async () => answer),
      () => {},
    );
    await expect(relay.current()).resolves.toBeNull();
    answer = { id: 'x' };
    await expect(relay.current()).rejects.toThrow('unreadably');
  });

  it('opens one stream for any number of subscribers and closes after the last', () => {
    const signals: AbortSignal[] = [];
    const open = vi.fn((signal: AbortSignal) => {
      signals.push(signal);
      return new Promise<Response>(() => {});
    });
    const relay = new ClusterSessionRelay(
      backendWith(async () => null),
      () => {},
      open,
    );
    relay.acquire();
    relay.acquire();
    expect(open).toHaveBeenCalledTimes(1);
    relay.release();
    expect(relay.active).toBe(true);
    relay.release();
    expect(relay.active).toBe(false);
    expect(signals[0].aborted).toBe(true);
    // A stale renderer's extra release can't go negative and block the next subscriber.
    relay.release();
    relay.acquire();
    expect(open).toHaveBeenCalledTimes(2);
    relay.reset();
    expect(signals[1].aborted).toBe(true);
    expect(relay.active).toBe(false);
  });

  it('publishes sessions split across chunks and opens the stream again when it ends', async () => {
    const first = stream();
    const second = stream();
    const open = vi
      .fn<(signal: AbortSignal) => Promise<Response>>()
      .mockResolvedValueOnce(first.response)
      .mockResolvedValueOnce(second.response)
      .mockReturnValue(new Promise(() => {}));
    const published: ClusterSession[] = [];
    // No session yet, so the catch-up read publishes nothing.
    const relay = new ClusterSessionRelay(
      backendWith(async () => null),
      (value) => published.push(value),
      open,
    );
    relay.acquire();
    const text = frame(session());
    first.write(text.slice(0, 40));
    first.write(text.slice(40) + frame(session(), 'state') + ': keepalive\n\n');
    await vi.waitFor(() => expect(published).toEqual([session()]));
    first.close();
    await vi.waitFor(() => expect(open).toHaveBeenCalledTimes(2), { timeout: 2000 });
    second.write(frame(session({ state: 'succeeded' })));
    await vi.waitFor(() =>
      expect(published.map((value) => value.state)).toEqual(['running', 'succeeded']),
    );
    relay.release();
  });

  it('catches up with the session as it is when the stream opens, unless a frame came first', async () => {
    const live = stream();
    const open = vi
      .fn<(signal: AbortSignal) => Promise<Response>>()
      .mockResolvedValueOnce(live.response)
      .mockReturnValue(new Promise(() => {}));
    const published: ClusterSession[] = [];
    const relay = new ClusterSessionRelay(
      backendWith(async () => session({ question: null, state: 'running' })),
      (value) => published.push(value),
      open,
    );
    relay.acquire();
    await vi.waitFor(() => expect(published).toHaveLength(1));
    live.write(frame(session({ state: 'failed' })));
    await vi.waitFor(() =>
      expect(published.map((value) => value.state)).toEqual(['running', 'failed']),
    );
    relay.release();

    const framed = stream();
    let answer!: (value: unknown) => void;
    const late = new ClusterSessionRelay(
      backendWith(() => new Promise((resolve) => (answer = resolve))),
      (value) => published.splice(0, published.length, value),
      vi
        .fn()
        .mockResolvedValueOnce(framed.response)
        .mockReturnValue(new Promise(() => {})),
    );
    late.acquire();
    await vi.waitFor(() => expect(answer).toBeTypeOf('function'));
    framed.write(frame(session({ state: 'succeeded' })));
    await vi.waitFor(() => expect(published[0]?.state).toBe('succeeded'));
    answer(session({ state: 'running' }));
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect(published.map((value) => value.state)).toEqual(['succeeded']);
    late.release();
  });

  it('drops an oversized stream and tries again', async () => {
    vi.useFakeTimers();
    try {
      const huge = stream();
      const open = vi
        .fn<(signal: AbortSignal) => Promise<Response>>()
        .mockResolvedValueOnce(huge.response)
        .mockReturnValue(new Promise(() => {}));
      const published: unknown[] = [];
      const relay = new ClusterSessionRelay(
        backendWith(async () => null),
        (value) => published.push(value),
        open,
      );
      relay.acquire();
      huge.write('x'.repeat(4_100_000));
      await vi.advanceTimersByTimeAsync(2500);
      expect(open).toHaveBeenCalledTimes(2);
      expect(published).toEqual([]);
      relay.release();
    } finally {
      vi.useRealTimers();
    }
  });

  it('opens a stream that went quiet again without waiting', async () => {
    vi.useFakeTimers();
    try {
      const signals: AbortSignal[] = [];
      const open = vi.fn((signal: AbortSignal) => {
        signals.push(signal);
        // A body that never speaks; aborting the request ends it, as fetch does.
        const body = new ReadableStream<Uint8Array>({
          start: (controller) =>
            signal.addEventListener('abort', () => controller.error(signal.reason)),
        });
        return Promise.resolve(new Response(body));
      });
      const relay = new ClusterSessionRelay(
        backendWith(async () => null),
        () => {},
        open,
      );
      relay.acquire();
      await vi.advanceTimersByTimeAsync(119_000);
      expect(open).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1500);
      expect(signals[0].aborted).toBe(true);
      expect(open).toHaveBeenCalledTimes(2);
      relay.release();
    } finally {
      vi.useRealTimers();
    }
  });
});
