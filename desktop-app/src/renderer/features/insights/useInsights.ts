import { useCallback, useEffect, useRef, useState } from 'react';
import type { Snapshot } from '../../../shared/contracts';
import { api } from '../../useBackend';
import { parseInsights, type ProviderInsights } from './types';

export function useInsights(state: Snapshot, window: '7d' | '30d' = '7d') {
  const key = state.linked
    ? `${state.installation_id}:${state.account_revision || 'legacy'}:${window}`
    : '';
  const [snapshot, setSnapshot] = useState<{
    key: string;
    data: ProviderInsights | null;
    error: string | null;
  }>({ key: '', data: null, error: null });
  const session = useRef<{ key: string; alive: boolean; busy: boolean } | null>(null);
  const refresh = useCallback(async () => {
    const current = session.current;
    if (!api || !current || !current.alive || current.busy) return;
    current.busy = true;
    try {
      const data = parseInsights(
        await api.read(window === '7d' ? 'insights-week' : 'insights-month'),
      );
      if (data.window !== window) throw new Error('Wrong earnings window');
      if (current.alive) setSnapshot({ key: current.key, data, error: null });
    } catch {
      if (current.alive)
        setSnapshot((previous) => ({
          key: current.key,
          data: previous.key === current.key ? previous.data : null,
          error: 'Earnings insights are unavailable. Check your connection and runtime version.',
        }));
    } finally {
      current.busy = false;
    }
  }, [window]);
  useEffect(() => {
    if (!key) return;
    const current = { key, alive: true, busy: false };
    session.current = current;
    void refresh();
    const timer = setInterval(() => {
      if (!document.hidden) void refresh();
    }, 30_000);
    const visible = () => {
      if (!document.hidden) void refresh();
    };
    document.addEventListener('visibilitychange', visible);
    return () => {
      current.alive = false;
      clearInterval(timer);
      document.removeEventListener('visibilitychange', visible);
      if (session.current === current) session.current = null;
    };
  }, [key, refresh]);
  return snapshot.key === key ? { ...snapshot, refresh } : { data: null, error: null, refresh };
}
