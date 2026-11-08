import type { Meta, StoryObj } from '@storybook/react-vite';
import { RuntimeSetup as SetupBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { RuntimeSetup as SetupAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { Updates as UpdatesBefore } from '../src/before/desktop-app/src/renderer/features/Updates';
import { Updates as UpdatesAfter } from '../src/after/desktop-app/src/renderer/features/Updates';
import { Cooling as CoolingBefore } from '../src/before/desktop-app/src/renderer/features/Cooling';
import { Cooling as CoolingAfter } from '../src/after/desktop-app/src/renderer/features/Cooling';
import type { CoolingData } from '../src/after/desktop-app/src/shared/contracts';
import { userEvent, within } from 'storybook/test';
import { Compare, Observed } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, poolSnapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Desktop runtime', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const generic = 'Could not connect to the runtime. Update or repair the installation.';

function Steps({ items, tone }: { items: string[]; tone: 'bad' | 'good' }) {
  return (
    <ol className={`sb-steps sb-steps-${tone}`}>
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ol>
  );
}

export const CrashRelaunch: Story = {
  name: '#1457 Relaunching after a crash',
  render: () => (
    <Compare
      pr={1457}
      title="After a crash or force quit, Darkbloom Preview never reconnected"
      wrong={
        <p>
          The preview starts its bundled API as a child process, which holds an exclusive lock and
          doesn't exit when the app dies. On relaunch every new API exited with “Desktop API is
          already running”, the app retried every 5 s forever, and <b>Repair runtime</b> failed
          too, until someone killed the leftover process by hand.
        </p>
      }
      fixed={
        <p>
          Before starting, the app stops the API its previous run left behind, but only after
          confirming the recorded pid is exactly this bundled binary running{' '}
          <code>desktop serve</code> (a reused pid is left alone).
        </p>
      }
      before={
        <>
          <SetupBefore
            backend={backendFor('before', undefined, {
              status: { state: 'error', message: generic },
            })}
          />
          <Steps
            tone="bad"
            items={[
              'Relaunch → spawn desktop serve',
              'Child exits: “Desktop API is already running” (stderr discarded)',
              'connection.json pid ≠ new child → “did not start”',
              'Retry every 5 s, indefinitely',
            ]}
          />
        </>
      }
      after={
        <>
          <Observed>
            Relaunch connects. The regression test abandons a running API (simulated crash),
            starts a fresh runtime for the same directory, and checks the old process is gone and
            a new one is serving.
          </Observed>
          <Steps
            tone="good"
            items={[
              'Relaunch → read recorded pid from connection.json',
              'ps confirms “<bundle>/darkbloom desktop serve” → SIGTERM (SIGKILL after 4 s)',
              'Spawn a new API → connected',
            ]}
          />
        </>
      }
    />
  ),
};

export const StartupError: Story = {
  name: '#1457 What a failed start tells you',
  render: () => (
    <Compare
      pr={1457}
      title="The API's own startup error was thrown away"
      wrong={
        <p>
          The bundled API ran with its output ignored, so its real reason for failing (lock held,
          discovery file unwritable, installed runtime not found) was lost and the user only saw
          a generic message.
        </p>
      }
      fixed={
        <p>
          A bounded tail of the API's stderr is kept and its last line is shown in the status the
          setup screen already displays.
        </p>
      }
      before={
        <SetupBefore
          backend={backendFor('before', undefined, {
            status: { state: 'error', message: generic },
          })}
        />
      }
      after={
        <SetupAfter
          backend={backendFor('after', undefined, {
            status: {
              state: 'error',
              message:
                'The bundled preview API did not start: Cannot publish desktop API discovery: disk full',
            },
          })}
        />
      }
    />
  ),
};

export const IncompatibleProtocol: Story = {
  name: '#1459 A runtime speaking another protocol',
  render: () => (
    <Compare
      pr={1459}
      title="An incompatible runtime was rejected, then connected anyway"
      wrong={
        <p>
          The app checked the runtime's protocol on connect and reported an error, but kept the
          connection. A quarter second later it opened the runtime's event stream, showed{' '}
          <b>Connected</b> and passed every unchecked snapshot to the UI.
        </p>
      }
      fixed={
        <p>
          A rejected runtime's connection is dropped, and every snapshot, including streamed ones,
          must pass the same check. A stream that changes protocol reconnects through the checked
          path.
        </p>
      }
      before={
        <>
          <Observed>Statuses emitted, from the regression test's loopback server (protocol 2):</Observed>
          <Steps
            tone="bad"
            items={[
              'error: Could not connect… (protocol mismatch)',
              'ready (event stream opened ~250 ms later)',
              'ready · protocol-2 snapshots forwarded to the UI',
            ]}
          />
        </>
      }
      after={
        <>
          <Observed>Same server:</Observed>
          <Steps tone="good" items={['error: Could not connect… (stays disconnected, retries)']} />
        </>
      }
    />
  ),
};

// #1483: the signed local preview bundles a desktop API built from the branch (0.9.17) but runs
// operations through the installed, released runtime (0.9.20), which has no `desktop` commands.
// The renderer is the same in both panes; what differs is what the native API reports.
const latest = { version: '0.9.20', published_at: '2026-10-12T00:00:00Z', notes: 'Reliability.' };
const releaseHistory = {
  history: [{ version: '0.9.20', published_at: '2026-10-12T00:00:00Z', notes: 'Reliability.', active: true }],
};
const stopped = (version: string) => poolSnapshot({}, { version, state: 'stopped' });

export const PreviewRuntimeVersion: Story = {
  name: '#1483 Update offered after updating',
  render: () => (
    <Compare
      pr={1483}
      title="The preview kept offering Update now after a successful update"
      wrong={
        <>
          <p>
            In the signed preview, the snapshot's <code>version</code> was the bundled desktop
            API's own build version (0.9.17), not the installed runtime's (0.9.20). Updates
            compared 0.9.17 with the latest 0.9.20 and offered <b>Update now</b>. Each click ran{' '}
            <code>darkbloom update</code>, which reported:
          </p>
          <Observed>Already up to date (v0.9.20). (5 times in the operation log)</Observed>
          <p>So the offer never went away.</p>
        </>
      }
      fixed={
        <p>
          The API reports the installed runtime's <code>--version</code>, re-read whenever an
          update replaces the executable. Checked on the installed preview: the running API now
          reports <code>0.9.20</code>. The renderer didn't change; both panes render the API's
          output before and after the native fix.
        </p>
      }
      before={<UpdatesBefore backend={backendFor('before', stopped('0.9.17'), { release: latest, releaseHistory })} />}
      after={<UpdatesAfter backend={backendFor('after', stopped('0.9.20'), { release: latest, releaseHistory })} />}
    />
  ),
};

const cooling = (control_available: boolean): CoolingData => ({
  supported: true,
  enabled: false,
  mode: 'automatic',
  observed_at: Date.now() / 1000,
  temperature: 48,
  fans: [
    { name: 'Left fan', rpm: 1200, max_rpm: 6000 },
    { name: 'Right fan', rpm: 1250, max_rpm: 6000 },
  ],
  speed: 75,
  threshold: 50,
  control_available,
});

export const PreviewRuntimeCooling: Story = {
  name: '#1483 Cooling with an older installed runtime',
  play: async ({ canvasElement }) => {
    const before = canvasElement.querySelector<HTMLElement>('.sb-before');
    if (before) await userEvent.click(within(before).getByRole('button', { name: 'Enable provider cooling' }));
  },
  render: () => (
    <Compare
      pr={1483}
      title="Enabling provider cooling failed with the runtime's usage text"
      wrong={
        <>
          <p>
            The preview offered cooling controls, but the installed 0.9.20 runtime has no{' '}
            <code>desktop configure-cooling</code> command. The play step clicks{' '}
            <b>Enable provider cooling</b> in Before; the real runtime answered:
          </p>
          <Observed>Error: Unknown option &apos;--enabled&apos; · Usage: darkbloom &lt;subcommand&gt; … (27 failed attempts)</Observed>
        </>
      }
      fixed={
        <p>
          The API probes <code>desktop --help</code> on the installed runtime, reports{' '}
          <code>control_available: false</code> when <code>configure-cooling</code> is missing, and
          refuses the action with “Darkbloom 0.9.20 doesn’t support this yet”. The page shows
          macOS-managed cooling. The wording (“does not report supported fan controls”) is
          existing copy and is noted as a limitation in the PR.
        </p>
      }
      before={<CoolingBefore backend={backendFor('before', poolSnapshot(), { cooling: cooling(true) })} embedded />}
      after={<CoolingAfter backend={backendFor('after', poolSnapshot(), { cooling: cooling(false) })} embedded />}
      log
    />
  ),
};
