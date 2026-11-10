import { useCallback, useEffect, useRef, useState } from 'react';
import type { Resource } from '../../shared/contracts';
import { api } from '../useBackend';

// Reads one native resource while the screen that shows it is mounted: at once, again whenever
// `refreshKey` changes (pass the snapshot's `resource_revision` for the native 30-second clock),
// when the window becomes visible, and on `refresh()`. A failed read keeps the last value and
// reports `error`; reads from an earlier mount are dropped.
export function useResource<T>(
  resource: Resource,
  { enabled = true, refreshKey }: { enabled?: boolean; refreshKey?: unknown } = {},
) {
  const [value, setValue] = useState<{ data?: T; error?: string; loading: boolean }>({
    loading: enabled,
  });
  const session = useRef<{ alive: boolean; request: number } | null>(null);
  const read = useCallback(async () => {
    const current = session.current;
    if (!api || !current?.alive) return;
    const request = ++current.request;
    try {
      const data = await api.read<T>(resource);
      if (current.alive && current.request === request)
        setValue({ data, error: undefined, loading: false });
    } catch (error) {
      if (current.alive && current.request === request)
        setValue((previous) => ({
          data: previous.data,
          error: error instanceof Error ? error.message : String(error),
          loading: false,
        }));
    }
  }, [resource]);
  useEffect(() => {
    if (!enabled) return;
    const current = { alive: true, request: 0 };
    session.current = current;
    void read();
    const visible = () => {
      if (!document.hidden) void read();
    };
    document.addEventListener('visibilitychange', visible);
    return () => {
      current.alive = false;
      document.removeEventListener('visibilitychange', visible);
      if (session.current === current) session.current = null;
    };
  }, [enabled, read, refreshKey]);
  return { ...value, refresh: read };
}
