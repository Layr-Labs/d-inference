import { useCallback, useEffect, useRef, useState } from 'react';
import type {
  Action,
  CloudData,
  CoolingData,
  DesktopAPI,
  DesktopStatus,
  Leader,
  NetworkData,
  ReleaseData,
  Route,
  Snapshot,
} from '../shared/contracts';
import { previewAPI } from './preview';

export const isPreview = import.meta.env.DEV && new URLSearchParams(location.search).has('preview');
export const api: DesktopAPI | undefined = isPreview ? previewAPI : window.darkbloom;
// Cooling status spawns a `darkbloom fan status` process in the native backend,
// so it is read only while a screen that displays it is shown.
export const showsCooling = (route: Route) => route === 'cooling';
export function useBackend(route: Route = 'home') {
  const [status, setStatus] = useState<DesktopStatus>({ state: 'connecting' });
  const [state, setState] = useState<Snapshot>();
  const [cloud, setCloud] = useState<CloudData>();
  const [network, setNetwork] = useState<NetworkData>();
  const [cooling, setCooling] = useState<CoolingData>();
  const [release, setRelease] = useState<ReleaseData>();
  const [leaders, setLeaders] = useState<Leader[]>([]);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const coolingVisible = useRef(showsCooling(route));
  const readCooling = useCallback(async () => {
    if (!api) return;
    await api
      .read<CoolingData>('cooling')
      .then(setCooling)
      .catch(() =>
        setCooling({
          supported: false,
          fans: [],
          mode: 'unavailable',
          error: 'Cooling status is unavailable.',
        }),
      );
  }, []);
  const refresh = useCallback(async () => {
    if (!api) return;
    await Promise.allSettled([
      api.read<Snapshot>('state').then(setState),
      api
        .read<CloudData>('cloud')
        .then(setCloud)
        .catch(() =>
          setCloud((previous) => ({
            linked: previous?.linked || false,
            observed_at: previous?.observed_at || 0,
            machines: previous?.machines || [],
            ...previous,
            error: 'Account data is unavailable. Showing the last observation.',
          })),
        ),
      api
        .read<NetworkData>('network')
        .then(setNetwork)
        .catch(() =>
          setNetwork((previous) => ({ ...previous, error: 'Network statistics are unavailable.' })),
        ),
      ...(coolingVisible.current ? [readCooling()] : []),
      api
        .read<ReleaseData>('release')
        .then(setRelease)
        .catch(() => setRelease({ error: 'Release information is unavailable.' })),
      api
        .read<{ entries?: Leader[] } | Leader[]>('leaderboard')
        .then((data) => setLeaders(Array.isArray(data) ? data : data.entries || [])),
    ]);
  }, [readCooling]);
  useEffect(() => {
    if (!api) {
      setStatus({
        state: 'missing',
        message: 'Open the Darkbloom desktop app to connect to this Mac.',
      });
      return;
    }
    api.status().then(setStatus);
    const offState = api.onState(setState);
    const offStatus = api.onStatus(setStatus);
    return () => {
      offState();
      offStatus();
    };
  }, []);
  useEffect(() => {
    if (status.state !== 'ready') return;
    void refresh();
    const timer = setInterval(() => {
      if (!document.hidden) void refresh();
    }, 30_000);
    return () => clearInterval(timer);
  }, [status.state, refresh]);
  const coolingShown = showsCooling(route);
  useEffect(() => {
    coolingVisible.current = coolingShown;
    // Entering the screen fetches at once (status is deliberately not a dependency:
    // the periodic refresh covers the rest, including the first refresh after the
    // runtime connects).
    if (coolingShown && status.state === 'ready') void readCooling();
  }, [coolingShown, readCooling]);
  const act = useCallback(
    async (action: Action, wait = false): Promise<boolean> => {
      if (!api) return false;
      setBusy(true);
      setError('');
      try {
        const operation = await api.act(action);
        if (wait) {
          const deadline = Date.now() + 40 * 60_000;
          while (Date.now() < deadline) {
            const latest = await api.read<Snapshot>('state');
            setState(latest);
            const current = latest.operations.find((item) => item.id === operation.id);
            if (current && current.state !== 'running') {
              if (current.state !== 'succeeded') throw new Error(current.message);
              await refresh();
              return true;
            }
            await new Promise((resolve) => setTimeout(resolve, 750));
          }
          throw new Error(
            'The operation is taking longer than expected. Check its status before retrying.',
          );
        }
        await refresh();
        return true;
      } catch (error) {
        setError(error instanceof Error ? error.message : 'The action failed');
        return false;
      } finally {
        setBusy(false);
      }
    },
    [refresh],
  );
  return {
    status,
    state,
    cloud,
    network,
    cooling,
    release,
    leaders,
    error,
    setError,
    busy:
      busy ||
      status.state !== 'ready' ||
      !!state?.operations.some((operation) => operation.state === 'running'),
    act,
    refresh,
  };
}
export type BackendState = ReturnType<typeof useBackend>;
