import { useCallback, useEffect, useRef, useState } from 'react';
import type {
  ClusterSession,
  ClusterSessionAnswer,
  ClusterSessionKind,
} from '../../../shared/cluster';
import { errorMessage } from '../../actions';
import { api } from '../../useBackend';

// A running session is read again when its stream says nothing for this long.
const silentMs = 5000;
const pollMs = 3000;

// The guided setup (`darkbloom cluster` with the app's screens) while the Clusters page is shown:
// a running session is restored when the page opens, then followed as the runtime streams it.
// The page shows a session from the moment it runs until the person leaves its outcome, except
// one cancelled here, which simply ends.
export function useClusterSession(
  enabled: boolean,
  onFinished?: (session: ClusterSession) => void,
) {
  const [session, setSession] = useState<ClusterSession | null>(null);
  const [shown, setShown] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [pending, setPending] = useState<'start' | 'answer' | null>(null);
  const cancelled = useRef<string | null>(null);
  const frames = useRef({ count: 0, at: 0 });
  const finished = useRef(onFinished);
  finished.current = onFinished;
  const last = useRef<ClusterSession | null>(null);

  const observe = useCallback((next: ClusterSession) => {
    const before = last.current;
    last.current = next;
    setSession(next);
    if (next.state === 'running') {
      setShown(next.id);
      return;
    }
    if (cancelled.current === next.id) setShown((id) => (id === next.id ? null : id));
    if (before?.id === next.id && before.state === 'running') finished.current?.(next);
  }, []);

  useEffect(() => {
    if (!enabled || !api) return;
    const bridge = api;
    let alive = true;
    const off = bridge.onClusterSession((next) => {
      if (!alive) return;
      frames.current = { count: frames.current.count + 1, at: Date.now() };
      observe(next);
    });
    const seen = frames.current.count;
    bridge.clusterSession().then(
      (current) => {
        if (alive && current && frames.current.count === seen) observe(current);
      },
      () => {},
    );
    return () => {
      alive = false;
      off();
    };
  }, [enabled, observe]);

  // A stream that went silent while the session runs (an older runtime, a dropped connection):
  // read the session instead until frames come again.
  const running = session?.state === 'running';
  useEffect(() => {
    if (!enabled || !running || !api) return;
    const bridge = api;
    const timer = setInterval(() => {
      if (Date.now() - frames.current.at < silentMs) return;
      const seen = frames.current.count;
      bridge.clusterSession().then(
        (current) => {
          if (current && frames.current.count === seen) observe(current);
        },
        () => {},
      );
    }, pollMs);
    return () => clearInterval(timer);
  }, [enabled, running, observe]);

  // A reply is taken unless the stream already said something newer.
  const send = async (call: () => Promise<ClusterSession>, failure: string) => {
    setError('');
    const seen = frames.current.count;
    try {
      const next = await call();
      if (frames.current.count === seen || next.id !== last.current?.id) observe(next);
      return next;
    } catch (cause) {
      setError(errorMessage(cause) || failure);
      return null;
    }
  };

  const start = async (kind: ClusterSessionKind) => {
    if (!api || pending) return;
    const bridge = api;
    setPending('start');
    try {
      const next = await send(
        () => bridge.startClusterSession({ kind }),
        'The setup didn’t start.',
      );
      if (next) setShown(next.id);
    } finally {
      setPending(null);
    }
  };

  const answer = async (value: ClusterSessionAnswer) => {
    if (!api || pending) return;
    const bridge = api;
    setPending('answer');
    try {
      await send(() => bridge.answerClusterSession(value), 'The setup didn’t take that answer.');
    } finally {
      setPending(null);
    }
  };

  const cancel = async () => {
    if (!session) return;
    cancelled.current = session.id;
    await answer({ cancel: true });
  };

  return {
    session,
    // The session the page shows instead of the status, if any.
    shown: session && shown === session.id ? session : null,
    error,
    pending,
    start,
    answer,
    cancel,
    dismiss: () => {
      setShown(null);
      setError('');
    },
    clearError: () => setError(''),
  };
}

export type ClusterSessionControl = ReturnType<typeof useClusterSession>;
