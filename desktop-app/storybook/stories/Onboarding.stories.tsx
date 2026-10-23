import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Onboarding as OnboardingBefore } from '../src/before/desktop-app/src/renderer/components/Onboarding';
import { Onboarding as OnboardingAfter } from '../src/after/desktop-app/src/renderer/components/Onboarding';
import AppBefore from '../src/before/desktop-app/src/renderer/App';
import AppAfter from '../src/after/desktop-app/src/renderer/App';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, models, snapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Onboarding and launch' };
export default meta;
type Story = StoryObj;

// What DesktopSnapshot.swift reports before anything is downloaded: catalog size, no memory_gb.
const freshInstall = () =>
  snapshot({
    state: 'stopped',
    models: models.map(({ memory_gb: _, ...model }) => ({
      ...model,
      downloaded: false,
      serving: false,
      loaded: false,
    })),
  });

const pressStart = async (canvasElement: HTMLElement) => {
  for (const pane of canvasElement.querySelectorAll<HTMLElement>('.sb-pane'))
    await userEvent.click(within(pane).getByRole('button', { name: /^Start/ }));
};

export const FreshInstallEligibility: Story = {
  name: '#1458 Fresh-install eligibility',
  beforeEach: () => resetBridges(),
  play: ({ canvasElement }) => pressStart(canvasElement),
  render: () => (
    <Compare
      pr={1458}
      title="Every Mac read “We couldn't confirm everything” on a fresh install"
      wrong={
        <>
          <p>
            The runtime reports a model's measured <code>memory_gb</code> only once it is
            downloaded. On a fresh install nothing is, so the memory check never had anything to
            compare with and stayed <i>unknown</i>, even on a 64 GB M4 Max.
          </p>
          <p>Watch the scan finish (about six seconds) in both panes.</p>
        </>
      }
      fixed={
        <p>
          A model not yet on the Mac counts by its catalog size, exactly as the runtime's own fit
          check (<code>modelFitsBudget</code>) does. Eligible Macs are confirmed; memory is blamed
          only when every model is larger than the Mac.
        </p>
      }
      before={<OnboardingBefore backend={backendFor('before', freshInstall())} done={() => {}} />}
      after={<OnboardingAfter backend={backendFor('after', freshInstall())} done={() => {}} />}
      height={720}
      stack
    />
  ),
};

const returning = (status: object) => ({
  beforeEach: () => {
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    resetBridges({ status: async () => status });
    return () => localStorage.removeItem('darkbloom.onboardingComplete');
  },
});

export const ColdLaunch: Story = {
  name: '#1456 Cold launch for a returning user',
  ...returning({ state: 'connecting' }),
  render: () => (
    <Compare
      pr={1456}
      title="Returning users saw first-run onboarding on every launch"
      wrong={
        <p>
          Until the runtime's first snapshot arrived (up to 90 s, or forever if it can't be
          reached), the app rendered first-run <b>Welcome</b> with a <b>Start</b> button, even for
          someone who finished onboarding long ago.
        </p>
      }
      fixed={
        <p>
          Returning users see the same brand screen with <b>Connecting to this Mac…</b>. First-run
          onboarding is unchanged. Both panes render the real <code>App</code>; no snapshot has
          arrived.
        </p>
      }
      before={<AppBefore />}
      after={<AppAfter />}
      height={640}
      stack
    />
  ),
};

export const ColdLaunchUnreachable: Story = {
  name: '#1456 Cold launch, runtime unreachable',
  ...returning({ state: 'error', message: 'Could not connect to the runtime.' }),
  render: () => (
    <Compare
      pr={1456}
      title="An unreachable runtime hid Repair behind “Start”"
      wrong={
        <p>
          With the runtime unreachable, returning users stayed on Welcome and had to press Start
          just to discover the Install/Repair screen.
        </p>
      }
      fixed={
        <p>
          Returning users go straight to the repair screen: “Darkbloom couldn’t start.” with{' '}
          <b>Repair CLI</b> in today's build (#1456 called it <b>Repair runtime</b>; #1502/#1504
          moved it to CLI terms).
        </p>
      }
      before={<AppBefore />}
      after={<AppAfter />}
      height={640}
      stack
    />
  ),
};
