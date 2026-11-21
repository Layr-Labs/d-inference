import type { Meta, StoryObj } from '@storybook/react-vite';
import { Earnings as EarningsBefore } from '../src/before/desktop-app/src/renderer/features/Earnings';
import { Earnings as EarningsAfter } from '../src/after/desktop-app/src/renderer/features/Earnings';
import { FleetEarnings as FleetBefore } from '../src/before/desktop-app/src/renderer/features/home/FleetEarnings';
import { FleetEarnings as FleetAfter } from '../src/after/desktop-app/src/renderer/features/home/FleetEarnings';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, poolSnapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Earnings and sign-in' };
export default meta;
type Story = StoryObj;

// Signing out (or a 30-day session expiring) clears the account session but keeps the provider link.
const signedOut = () => ({
  ...poolSnapshot(),
  linked: true,
  account: { signed_in: false, legacy_data: false },
});

const explain = {
  pr: 1460,
  wrong: (
    <p>
      Earnings are read with the account session, but these screens decided what to show from the
      Mac's provider <i>link</i>. A linked Mac that signed out (or whose session expired) waited on
      <b> Loading…</b> forever, for data that was never requested, with no retry.
    </p>
  ),
  fixed: (
    <p>
      The earnings hook reports whether it can load at all; a linked but signed-out Mac is asked to{' '}
      <b>sign in</b>. Signed-in accounts still show loading while reading.
    </p>
  ),
};

export const EarningsPage: Story = {
  name: '#1460 Earnings page',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      {...explain}
      title="Earnings said “Loading…” forever after signing out"
      before={<EarningsBefore backend={backendFor('before', signedOut())} />}
      after={<EarningsAfter backend={backendFor('after', signedOut())} />}
    />
  ),
};

export const HomeChart: Story = {
  name: '#1460 Home daily earnings',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      {...explain}
      title="Home's daily earnings chart said “Loading…” forever"
      before={<FleetBefore backend={backendFor('before', signedOut())} onEarnings={() => {}} />}
      after={<FleetAfter backend={backendFor('after', signedOut())} onEarnings={() => {}} />}
    />
  ),
};
