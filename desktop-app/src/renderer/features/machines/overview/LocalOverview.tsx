import { useMemo } from 'react';
import type { Route } from '../../../../shared/contracts';
import type { BackendState } from '../../../useBackend';
import { HealthBar } from './HealthBar';
import { MacEarnings } from './MacEarnings';
import { TokensChart } from './TokensChart';
import { hourlyTokens } from './hourlyTokens';
import { ServingModels } from './ServingModels';

export function LocalOverview({
  backend,
  navigate,
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
}) {
  const state = backend.state!;
  const cloud = backend.cloud;
  const { samples } = state.activity;
  const buckets = useMemo(
    () => hourlyTokens(samples, state.observed_at),
    [samples, state.observed_at],
  );
  return (
    <>
      <HealthBar backend={backend} navigate={navigate} />
      <MacEarnings
        label="This Mac’s earnings"
        lifetime={cloud?.local_lifetime_micro_usd}
        day={cloud?.local_day_micro_usd}
        week={cloud?.local_earnings_micro_usd}
      >
        {!state.linked
          ? 'Link this Mac to see what it earns.'
          : cloud &&
            (!cloud.local_lifetime_micro_usd || !cloud.local_day_micro_usd) &&
            'Per-Mac totals appear here once your Darkbloom runtime reports them.'}
      </MacEarnings>
      <TokensChart buckets={buckets} now={state.observed_at} />
      <ServingModels
        state={state}
        models={state.machine.models}
        onManage={() => navigate('models')}
      />
    </>
  );
}
