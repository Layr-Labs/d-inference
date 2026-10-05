import { useCallback, useEffect, useRef, useState } from 'react';
import type { RequestHistory } from '../../../../shared/contracts';
import { api } from '../../../useBackend';
import { parseRequestHistory } from './requests';

export function useRequestHistory(scope = 'current', revision?: string) {
  const [result, setResult] = useState<{
    scope: string;
    history?: RequestHistory;
    loading: boolean;
    failed: boolean;
  }>({ scope, loading: true, failed: false });
  const latest = useRef(0);
  const load = useCallback(async () => {
    const request = ++latest.current;
    setResult((previous) => ({
      scope,
      history: previous.scope === scope ? previous.history : undefined,
      loading: true,
      failed: false,
    }));
    try {
      if (!api) throw new Error('The runtime is not connected');
      const history = parseRequestHistory(await api.read('request-history'));
      if (request === latest.current) setResult({ scope, history, loading: false, failed: false });
    } catch {
      if (request === latest.current)
        setResult((previous) => ({
          scope,
          history: previous.scope === scope ? previous.history : undefined,
          loading: false,
          failed: true,
        }));
    }
  }, [scope]);
  useEffect(() => {
    void load();
    return () => {
      latest.current++;
    };
  }, [load, revision]);
  return {
    ...(result.scope === scope ? result : { history: undefined, loading: true, failed: false }),
    refresh: load,
  };
}
