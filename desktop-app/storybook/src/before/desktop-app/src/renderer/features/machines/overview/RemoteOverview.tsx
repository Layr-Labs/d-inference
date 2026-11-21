import { useMemo } from 'react';
import type { Machine } from '../../../../shared/contracts';
import type { BackendState } from '../../../useBackend';
import { publishedVersions, releaseStatus } from '../../updates/version';
import { RemoteStats } from './RemoteStats';
import { RemoteStatus } from './RemoteStatus';
import { ServingModels } from './ServingModels';
import { TokensChart } from './TokensChart';
import { clockTime } from '../../../format';
import { reportedHours } from './hourlyTokens';
import { remotePresence } from './presence';

export function RemoteOverview({ machine, backend }: { machine: Machine; backend: BackendState }) {
  const state = backend.state!;
  const now = state.observed_at;
  const presence = remotePresence(machine, now);
  const observed = machine.observed_at ?? now;
  const buckets = useMemo(
    () => machine.hourly_tokens && reportedHours(machine.hourly_tokens, observed),
    [machine.hourly_tokens, observed],
  );
  const { minimum } = publishedVersions(backend);
  const updateRequired =
    !!machine.version && releaseStatus(machine.version, undefined, minimum) === 'required';
  return (
    <>
      <RemoteStatus machine={machine} presence={presence} />
      <RemoteStats
        machine={machine}
        presence={presence}
        now={now}
        updateRequired={updateRequired}
      />
      {buckets && (
        <TokensChart
          buckets={buckets}
          now={observed}
          until={presence === 'online' ? 'Now' : clockTime(observed, now)}
          dense
        />
      )}
      <ServingModels state={state} models={machine.models} inline />
    </>
  );
}
