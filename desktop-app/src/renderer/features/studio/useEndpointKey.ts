import { useEffect, useRef, useState } from 'react';
import type { BackendState } from '../../useBackend';
import { api } from '../../useBackend';

// The local API key, read only on an explicit Reveal. Local credentials are independent of account
// sign-in: ordinary snapshots and model changes keep a reveal, while a new endpoint, runtime or
// provider session needs another explicit Reveal, and a read that resolves for an obsolete one is
// ignored.
export function useEndpointKey(backend: BackendState, report: (problem: string) => void) {
  const state = backend.state!;
  const endpoint = state.endpoint;
  const [revealed, setKey] = useState<{ identity: string; key: string }>();
  const session = useRef<{ identity: string; alive: boolean; request: number } | null>(null);
  const identity =
    endpoint?.authenticated && backend.status.state === 'ready'
      ? JSON.stringify([state.installation_id, state.activity.started_at, endpoint.base_url])
      : undefined;
  useEffect(() => {
    setKey(undefined);
    if (!identity) return;
    const current = { identity, alive: true, request: 0 };
    session.current = current;
    return () => {
      current.alive = false;
      if (session.current === current) session.current = null;
    };
  }, [identity]);
  // Also mask during the render that precedes effect cleanup for a changed endpoint.
  const key = revealed?.identity === identity ? revealed?.key : undefined;
  const toggle = async () => {
    const current = session.current;
    if (!identity || !current?.alive || current.identity !== identity) return;
    const request = ++current.request;
    if (key) return setKey(undefined);
    try {
      report('');
      const value = await api?.read<{ key: string }>('endpoint-key');
      if (current.alive && current.request === request)
        setKey(value?.key ? { identity: current.identity, key: value.key } : undefined);
    } catch {
      if (current.alive && current.request === request)
        report('Couldn’t read the API key. Try again.');
    }
  };
  return { key, available: !!identity, toggle };
}

export type EndpointKey = ReturnType<typeof useEndpointKey>;
