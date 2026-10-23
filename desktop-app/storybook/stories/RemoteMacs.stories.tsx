import type { Meta, StoryObj } from '@storybook/react-vite';
import { RemoteOverview as RemoteBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/RemoteOverview';
import { RemoteOverview as RemoteAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/RemoteOverview';
import type { BackendState } from '../src/after/desktop-app/src/renderer/useBackend';
import type { Machine } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { previewBackend } from './support/fixtures';

const meta: Meta = {
  title: 'Fixes/My Macs/View-only Macs',
  loaders: [async () => ({ backend: await previewBackend() })],
  beforeEach: () => resetBridges(),
};
export default meta;
type Story = StoryObj;

const studio = (backend: BackendState) => backend.cloud!.machines[0];
const show = (backend: BackendState, machine: Machine) => ({
  before: <RemoteBefore backend={backend} machine={machine} />,
  after: <RemoteAfter backend={backend} machine={machine} />,
});

export const AwaitingVerification: Story = {
  name: '#1464 Mac awaiting verification, partial tokens',
  render: (_, { loaded }) => {
    const machine = { ...studio(loaded.backend), status: 'untrusted', tokens_24h: { output: 1000 } };
    return (
      <Compare
        pr={1464}
        title="A view-only Mac awaiting verification read “Offline”, with an undercounted total"
        wrong={
          <ul>
            <li>
              Every status other than running/online/serving was shown as <b>Offline</b>, while the
              rail and Home said <i>Verification needed</i>, <i>Starting</i> or <i>Finishing
              requests</i>.
            </li>
            <li>
              <b>Tokens served</b> added missing input as 0: 1K beside “Input tokens —”.
            </li>
          </ul>
        }
        fixed={
          <p>
            The pill shows the reported status, and the total is shown only when every part is
            reported.
          </p>
        }
        {...show(loaded.backend, machine)}
      />
    );
  },
};

export const NeverObserved: Story = {
  name: '#1464 Mac with no observation time',
  render: (_, { loaded }) => {
    const machine = { ...studio(loaded.backend), observed_at: undefined };
    return (
      <Compare
        pr={1464}
        title="“Last observed not observed”"
        wrong={
          <p>
            Without an observation time the status read <b>Last observed not observed</b>, and the
            hourly chart was anchored to the current hour although nothing supports that alignment.
          </p>
        }
        fixed={<p>It says <b>Not observed yet</b> and doesn't draw an unanchored chart.</p>}
        {...show(loaded.backend, machine)}
      />
    );
  },
};

export const OlderObservation: Story = {
  name: '#1464 Mac last observed three days ago',
  render: (_, { loaded }) => {
    const machine = {
      ...studio(loaded.backend),
      status: 'offline',
      observed_at: loaded.backend.state!.observed_at - 3 * 86400 + 1800,
    };
    return (
      <Compare
        pr={1464}
        title="Older observations lowercased the month in the chart"
        wrong={
          <p>
            Hover or focus the last bar of the hourly chart: the open hour's range lowercased its
            whole end label, producing “2 PM – <b>oct 10, 2:47 pm</b>”.
          </p>
        }
        fixed={<p>Only “now” is lowercased; dates keep their capitalization.</p>}
        {...show(loaded.backend, machine)}
      />
    );
  },
};
