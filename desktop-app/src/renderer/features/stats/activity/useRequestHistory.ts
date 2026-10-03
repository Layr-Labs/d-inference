import { useCallback, useEffect, useRef, useState } from 'react';
import type { RequestHistory } from '../../../../shared/contracts';
import { api } from '../../../useBackend';
import { parseRequestHistory } from './requests';

// Read when the Activity view opens and on manual refresh, never in the
// periodic refresh: the history grows with every request served.
export function useRequestHistory() {
  const [result, setResult] = useState<{
    history?: RequestHistory;
    loading: boolean;
    failed: boolean;
  }>({ loading: true, failed: false });
  const latest = useRef(0);
  const load = useCallback(async () => {
    const request = ++latest.current;
    setResult((previous) => ({ ...previous, loading: true }));
    try {
      if (!api) throw new Error('The runtime is not connected');
      const history = parseRequestHistory(await api.read('request-history'));
      if (request === latest.current) setResult({ history, loading: false, failed: false });
    } catch {
      if (request === latest.current)
        setResult((previous) => ({ history: previous.history, loading: false, failed: true }));
    }
  }, []);
  useEffect(() => {
    void load();
    return () => {
      latest.current++;
    };
  }, [load]);
  return { ...result, refresh: load };
}
