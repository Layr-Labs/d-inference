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
  ReleaseHistory,
  Route,
  Snapshot,
} from '../shared/contracts';
import { submitAction } from './actions';
import { pageResources } from './data/pageResources';
import { previewAPI } from './preview';
import { parseReleaseHistory } from './features/updates/version';
import { parseLeaderboard } from './features/leaderboard/data';
import { showsLocalOverview, type MachineSelection } from './features/machines/navigation';

export const isPreview = import.meta.env.DEV && new URLSearchParams(location.search).has('preview');
export const api: DesktopAPI | undefined = isPreview ? previewAPI : window.darkbloom;
// Cooling status spawns a `darkbloom fan status` process in the native backend,
// so it is read only while a screen that displays it is shown: Cooling and
// This Mac's Overview.
export const showsCooling = (route: Route, machine: MachineSelection = null) =>
  route === 'cooling' || showsLocalOverview(route, machine);
export function useBackend(route: Route = 'home', machine: MachineSelection = null) {
  const [status, setStatus] = useState<DesktopStatus>({ state: 'connecting' });
  const [state, setState] = useState<Snapshot>();
  const [cloud, setCloud] = useState<CloudData>();
  const [network, setNetwork] = useState<NetworkData>();
  const [cooling, setCooling] = useState<CoolingData>();
  const [release, setRelease] = useState<ReleaseData>();
  const [releaseHistory, setReleaseHistory] = useState<ReleaseHistory>();
  const [leaders, setLeaders] = useState<Leader[]>([]);
  const [leaderError, setLeaderError] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const accountGeneration = useRef(0);
  const accountRevision = useRef<string | undefined>(undefined);
  const observeState = useCallback((snapshot: Snapshot) => {
    if (
      accountRevision.current !== undefined &&
      snapshot.account_revision !== accountRevision.current
    ) {
      accountGeneration.current++;
      setCloud(undefined);
    }
    accountRevision.current = snapshot.account_revision;
    setState(snapshot);
  }, []);
  const coolingVisible = useRef(showsCooling(route, machine));
  coolingVisible.current = showsCooling(route, machine);
  const visibleResources = useRef(pageResources(route));
  visibleResources.current = pageResources(route);
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
  const refreshVisible = useCallback(
    async (includeCooling = true) => {
      if (!api) return;
      const generation = accountGeneration.current;
      const accept =
        <T>(setter: (value: T) => void) =>
        (value: T) => {
          if (generation === accountGeneration.current) setter(value);
        };
      await Promise.allSettled([
        ...(visibleResources.current.includes('cloud')
          ? [
              api
                .read<CloudData>('cloud')
                .then(accept(setCloud))
                .catch(() => {
                  if (generation !== accountGeneration.current) return;
                  setCloud((previous) => ({
                    linked: previous?.linked || false,
                    observed_at: previous?.observed_at || 0,
                    machines: previous?.machines || [],
                    ...previous,
                    error: previous?.observed_at
                      ? 'Account data unavailable. Last update: ' +
                        new Date(previous.observed_at * 1000).toLocaleTimeString([], {
                          hour: 'numeric',
                          minute: '2-digit',
                        })
                      : 'Account data unavailable.',
                  }));
                }),
            ]
          : []),
        ...(visibleResources.current.includes('network')
          ? [
              api
                .read<NetworkData>('network')
                .then(setNetwork)
                .catch(() =>
                  setNetwork((previous) => ({
                    ...previous,
                    error: 'Network statistics are unavailable.',
                  })),
                ),
            ]
          : []),
        ...(includeCooling && coolingVisible.current ? [readCooling()] : []),
        ...(visibleResources.current.includes('release')
          ? [
              api
                .read<ReleaseData>('release')
                .then(setRelease)
                .catch(() => setRelease({ error: 'Release information is unavailable.' })),
            ]
          : []),
        ...(visibleResources.current.includes('release-history')
          ? [
              api
                .read<ReleaseHistory>('release-history')
                .then((value) => setReleaseHistory(parseReleaseHistory(value)))
                .catch(() =>
                  setReleaseHistory({
                    history: [],
                    error: 'Release history and support policy are unavailable.',
                  }),
                ),
            ]
          : []),
        ...(visibleResources.current.includes('leaderboard')
          ? [
              api
                .read<unknown>('leaderboard')
                .then((data) => {
                  setLeaders(parseLeaderboard(data));
                  setLeaderError('');
                })
                .catch(() => setLeaderError('Rankings could not refresh.')),
            ]
          : []),
      ]);
    },
    [readCooling],
  );
  const refresh = useCallback(async () => {
    await Promise.allSettled([api?.read<Snapshot>('state').then(observeState), refreshVisible()]);
  }, [refreshVisible, observeState]);
  useEffect(() => {
    if (!api) {
      setStatus({
        state: 'missing',
        message: 'Open the Darkbloom desktop app to connect to this Mac.',
      });
      return;
    }
    api.status().then(setStatus);
    const offState = api.onState(observeState);
    const offStatus = api.onStatus(setStatus);
    return () => {
      offState();
      offStatus();
    };
  }, []);
  useEffect(() => {
    if (status.state !== 'ready') return;
    void refresh();
  }, [status.state, refresh]);
  useEffect(() => {
    if (status.state === 'ready') void refreshVisible(false);
  }, [route, refreshVisible]);
  useEffect(() => {
    if (status.state !== 'ready' || document.hidden || !state?.resource_revision) return;
    void refreshVisible();
  }, [state?.resource_revision, state?.account_revision]);
  const coolingShown = showsCooling(route, machine);
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
        if (wait) {
          await submitAction(api, action, {
            timeoutMs: 40 * 60_000,
            timeout:
              'The operation is taking longer than expected. Check its status before retrying.',
          });
        } else {
          await api.act(action);
        }
        await refreshVisible();
        return true;
      } catch (error) {
        setError(error instanceof Error ? error.message : 'The action failed');
        return false;
      } finally {
        setBusy(false);
      }
    },
    [refreshVisible],
  );
  return {
    status,
    state,
    cloud,
    network,
    cooling,
    release,
    releaseHistory,
    leaders,
    leaderError,
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
