import { useEffect, useRef, useState, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import App from '../../src/after/desktop-app/src/renderer/App';
import { AccountControl } from '../../src/after/desktop-app/src/renderer/components/AccountControl';
import { Home } from '../../src/after/desktop-app/src/renderer/features/Home';
import { FanStatus } from '../../src/after/desktop-app/src/renderer/features/home/chip/FanStatus';
import { FanHealth } from '../../src/after/desktop-app/src/renderer/features/machines/overview/FanHealth';
import { HealthBar } from '../../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { MemoryHealth } from '../../src/after/desktop-app/src/renderer/features/machines/overview/MemoryHealth';
import { RemoteStatus } from '../../src/after/desktop-app/src/renderer/features/machines/overview/RemoteStatus';
import { remotePresence } from '../../src/after/desktop-app/src/renderer/features/machines/overview/presence';
import { previewAPI } from '../../src/after/desktop-app/src/renderer/preview';
import type { BackendState } from '../../src/after/desktop-app/src/renderer/useBackend';
import type {
  CloudData,
  CoolingData,
  DesktopStatus,
  Machine,
  Operation,
  ReleaseData,
  Snapshot,
} from '../../src/after/desktop-app/src/shared/contracts';
import { poolModels } from '../../src/after/desktop-app/tests/modelsFixtures';
import { Walkthrough, type Step } from '../support/Walkthrough';
import { resetBridges } from '../support/bridge';
import { backendFor, models, poolSnapshot, snapshot } from '../support/fixtures';

const meta: Meta = { title: 'Flows/Status checks', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const noop = () => {};
const now = () => Math.floor(Date.now() / 1000);

const cooling: CoolingData = {
  supported: true,
  enabled: true,
  observed_at: now(),
  mode: 'automatic',
  temperature: 58,
  fans: [
    { name: 'Left fan', rpm: 2480, max_rpm: 5200 },
    { name: 'Right fan', rpm: 2510, max_rpm: 5200 },
  ],
};

const backend = (state: Snapshot, extra: Partial<BackendState> = {}) =>
  backendFor('after', state, { cooling, ...extra });

const running = (overrides: Partial<Snapshot> = {}) => poolSnapshot({}, overrides);
// Stopped, with the pool's models still chosen (serving) but nothing loaded.
const stopped = (overrides: Partial<Snapshot> = {}) =>
  poolSnapshot({}, {
    state: 'stopped',
    models: poolModels.map((model) => ({ ...model, loaded: false })),
    memory: { total_gb: 64 },
    ...overrides,
  });
const operation = (action: Operation['action'], message = ''): Operation => ({
  id: `${action}-running`,
  action,
  state: 'running',
  started_at: 1_790_000_000,
  message,
  cancellable: false,
});

/** This Mac's Overview health section, as LocalOverview renders it. */
const health = (b: BackendState) => <HealthBar backend={b} navigate={noop} />;

function code(text: string) {
  return <code>{text}</code>;
}

// ---------------------------------------------------------------------------------------------

export const ProviderLifecycle: Story = {
  name: 'This Mac: provider lifecycle',
  render: () => (
    <Walkthrough
      title="This Mac: provider lifecycle"
      intro={
        <p>
          My Macs › This Mac › Overview. <code>HealthBar</code> runs{' '}
          <code>assessReadiness</code> (<code>readiness.ts</code>) over the runtime status, the
          snapshot and the update policy. Tone is <i>ready</i>, <i>pending</i> (amber, waiting on
          something) or <i>blocked</i> (needs action). The headline comes from the first non-link
          step; <code>providerStep</code> (<code>readinessSteps.ts</code>) picks the single most
          relevant provider fact in this order: draining, starting, stale, verification, network,
          nothing downloaded, stopped, nothing chosen, crashed, still loading. A running lifecycle
          operation (start, switch, stop, restart, update) suppresses the provider step.
        </p>
      }
      steps={[
        {
          label: 'Ready to serve',
          note: (
            <p>
              {code("state: 'running'")}, two models {code('serving')} and {code('loaded')}, no
              running operation: green tone, “Ready to serve · 2 models loaded”, memory split into
              active and cache, both fans reported. No Next steps.
            </p>
          ),
          node: health(backend(running())),
        },
        {
          label: 'Stopped, models chosen',
          note: (
            <p>
              {code("state: 'stopped'")} with downloaded, eligible models still chosen: blocked,
              headline <b>Stopped</b>, Next step “Start serving” naming them, with{' '}
              <b>Start serving</b> (sends {code('start')} with exactly those ids) and{' '}
              <b>Choose models</b>. Memory reads “64 GB total · Reported while this Mac is
              serving.” (“Start providing” and “while the provider runs” before #1501.)
            </p>
          ),
          prs: [1501],
          node: health(backend(stopped())),
        },
        {
          label: 'Stopped, nothing chosen',
          note: (
            <p>
              Stopped with a downloaded model that isn't chosen ({code('serving: false')}): the
              step becomes “Choose models to serve”, and that title is also the headline.
            </p>
          ),
          node: health(backend(snapshot())),
        },
        {
          label: 'Nothing downloaded',
          note: (
            <p>
              No model has {code('downloaded: true')} (a fresh install): “Download a model” with{' '}
              <b>Browse models</b>, whatever the provider state.
            </p>
          ),
          node: health(
            backend(snapshot({ models: models.map((model) => ({ ...model, downloaded: false })) })),
          ),
        },
        {
          label: 'Start requested',
          note: (
            <p>
              A running {code('start')} operation while the snapshot still says stopped: pending
              tone, headline “Starting to serve” (the operation's label; “Starting provider” before
              #1501), Next step “Wait for it to finish.” The stopped step is suppressed while the
              operation runs.
            </p>
          ),
          prs: [1501],
          node: health(backend(stopped({ operations: [operation('start')] }), { busy: true })),
        },
        {
          label: 'Provider starting',
          note: (
            <p>
              {code("state: 'starting'")}: pending, “Starting to serve · Requests are served once
              this Mac connects.”
            </p>
          ),
          prs: [1501],
          node: health(backend(running({ state: 'starting', memory: { total_gb: 64 } }))),
        },
        {
          label: 'Loading models',
          note: (
            <p>
              Running with models chosen but none {code('loaded')} yet: pending, “Loading models”
              naming both.
            </p>
          ),
          node: health(
            backend(running({ models: poolModels.map((model) => ({ ...model, loaded: false })) })),
          ),
        },
        {
          label: 'Running, nothing chosen',
          note: (
            <p>
              Running with no model {code('serving')}: blocked, “Choose models to serve · Select at
              least one downloaded model.”
            </p>
          ),
          node: health(
            backend(
              running({ models: poolModels.map((model) => ({ ...model, serving: false, loaded: false })) }),
            ),
          ),
        },
        {
          label: 'A model crashed',
          note: (
            <p>
              {code("activity.models[].state: 'crashed'")}: blocked, headline “Needs restart”,
              “GPT-OSS 20B stopped unexpectedly.” with <b>Restart serving</b> (“Restart provider”
              before #1501).
            </p>
          ),
          prs: [1501],
          node: health(
            backend(
              running({
                activity: {
                  samples: [],
                  models: [
                    { model: 'gpt-oss-20b', state: 'crashed', running: 0, waiting: 0 },
                    { model: 'gemma-4-26b', state: 'idle', running: 0, waiting: 0 },
                  ],
                },
              }),
            ),
          ),
        },
        {
          label: 'Draining',
          note: (
            <p>
              {code("state: 'draining'")} (stopping after current requests): pending, “Finishing
              current requests · This Mac takes no new requests while it finishes the current
              ones.”
            </p>
          ),
          prs: [1501],
          node: health(backend(running({ state: 'draining' }))),
        },
        {
          label: 'Stale status',
          note: (
            <p>
              {code("state: 'stale'")} (the provider runs but stopped reporting): blocked,
              headline “Status unavailable”, “Restart serving · This Mac is still serving, but its
              status is out of date.” with <b>Restart serving</b>.
            </p>
          ),
          prs: [1501],
          node: health(backend(running({ state: 'stale' }))),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const cloudWith = (minimum: string): CloudData => ({
  linked: true,
  observed_at: now(),
  machines: [],
  minimum_provider_version: minimum,
});
const release = (version: string): ReleaseData => ({
  version,
  published_at: new Date().toISOString(),
  notes: 'Fixture release',
});
const old = () => running({ version: '0.9.2' });

export const NetworkAccountUpdates: Story = {
  name: 'This Mac: network, account and updates',
  play: async ({ canvasElement }) => {
    const step = within(within(canvasElement).getByRole('region', { name: 'Link code waiting' }));
    await userEvent.click(step.getByRole('button', { name: 'Copy code' }));
    await step.findByRole('button', { name: 'Copied' });
  },
  render: () => (
    <Walkthrough
      title="This Mac: network, account and updates"
      intro={
        <p>
          The same Overview health section for facts outside the provider process: the
          coordinator's view of this Mac ({code('provider_status')}), the account link, and the
          supported-version floor. Linking is advice only: it adds a step but never changes the
          tone. A required update always blocks.
        </p>
      }
      log
      steps={[
        {
          label: 'Verification needed',
          note: (
            <p>
              {code("provider_status: 'untrusted'")}: blocked, “Verification needed · This Mac is
              not authorized to receive network requests yet.” No action is offered.
            </p>
          ),
          prs: [1464],
          node: health(backend(running({ provider_status: 'untrusted' }))),
        },
        {
          label: 'Not connected to the network',
          note: (
            <p>
              {code("provider_status: 'offline'")} while the provider runs: pending, “Connecting to
              the network”.
            </p>
          ),
          node: health(backend(running({ provider_status: 'offline' }))),
        },
        {
          label: 'Not linked',
          note: (
            <p>
              {code('linked: false')}, otherwise serving: still green “Ready to serve”, plus “Link
              this Mac” with <b>Link account</b>.
            </p>
          ),
          prs: [1471],
          node: health(backend(running({ linked: false }))),
        },
        {
          label: 'Link code waiting',
          note: (
            <p>
              {code('link.code')} present: the step becomes “Finish linking this Mac · Enter this
              code on the link page…”, shows the code on its own line in large, letter-spaced type
              with <b>Copy code</b>, and offers <b>Open link page</b> instead of requesting another
              code. Until the #1471 follow-up the code was buried in the sentence (“Enter code
              BLOOM-7Q4K in your browser…”). The play step clicks <b>Copy code</b> (it reads
              “Copied”; the log shows the copy).
            </p>
          ),
          prs: [1471],
          node: health(
            backend(
              running({
                linked: false,
                link: { url: 'https://example.invalid/link', code: 'BLOOM-7Q4K', expires_at: 1_790_000_900, state: 'pending' },
              }),
            ),
          ),
        },
        {
          label: 'Required update available',
          note: (
            <p>
              Runtime {code('0.9.2')} below the account's {code('minimum_provider_version')}{' '}
              {code('0.9.10')}, latest release {code('0.9.16')}: blocked, headline “Update
              Darkbloom”, “This version can no longer receive network requests.” with{' '}
              <b>Update now</b>. My Macs now loads the release resources, so this shows without
              visiting Updates first.
            </p>
          ),
          prs: [1454],
          node: health(backend(old(), { cloud: cloudWith('0.9.10'), release: release('0.9.16') })),
        },
        {
          label: 'Required update, none compatible yet',
          note: (
            <p>
              Same floor, but the latest release ({code('0.9.8')}) is itself below it: blocked,
              and the step says a compatible update isn't available yet, with no button.
            </p>
          ),
          prs: [1454],
          node: health(backend(old(), { cloud: cloudWith('0.9.10'), release: release('0.9.8') })),
        },
        {
          label: 'Update running',
          note: (
            <p>
              A running {code('update')} operation on a below-floor runtime: pending, headline
              “Updating Darkbloom”, one step “Updating Darkbloom · Wait for it to finish.” Before
              #1491 the required update step was also listed, with <b>Update now</b>, and kept the
              blocked “Update Darkbloom” headline; a running update now suppresses it until the
              update ends (fixed by #1491).
            </p>
          ),
          prs: [1454, 1491],
          node: health(
            backend(running({ version: '0.9.2', operations: [operation('update')] }), {
              cloud: cloudWith('0.9.10'),
              release: release('0.9.16'),
              busy: true,
            }),
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const on26 = { system: { macosVersion: '26.5' } };
const promptKey = 'darkbloom.macos-prompt-dismissed';
const clearPrompt = () => {
  try {
    sessionStorage.removeItem(promptKey);
  } catch {
    // Storage blocked: the notice shows anyway.
  }
};

export const Macos26: Story = {
  name: 'This Mac: macOS 26 Mac',
  beforeEach: () => {
    clearPrompt();
    resetBridges();
    return clearPrompt;
  },
  play: async ({ canvasElement }) => {
    const step = (label: string) => within(within(canvasElement).getByRole('region', { name: label }));
    await userEvent.click(step('Update macOS, serving').getByRole('button', { name: 'Open Software Update' }));
    await userEvent.click(step('Home: notice dismissed').getByRole('button', { name: 'Dismiss' }));
  },
  render: () => (
    <Walkthrough
      title="This Mac: macOS 26 Mac"
      intro={
        <p>
          An existing provider whose Mac runs macOS 26.5 (the main process's{' '}
          {code('api.system()')}). New providers need macOS 27 or later (#1506); existing ones keep
          serving (the coordinator decides whether they stay authorized) and are prompted to
          update. <code>assessReadiness</code> adds an <b>Update macOS</b> step (
          {code("id: 'macos'")}) after the update, provider and operation steps and before linking.
          Like linking, it is advice: it never changes the tone and is never the headline. On macOS
          27 or later, or when the version is unknown, nothing is added. The play step clicks{' '}
          <b>Open Software Update</b> in step 1 (the log shows {code('openSoftwareUpdate')}) and
          dismisses Home's notice in the last step.
        </p>
      }
      log
      steps={[
        {
          label: 'Update macOS, serving',
          note: (
            <p>
              Serving, linked, on 26.5: still green “Ready to serve · 2 models loaded”, with one
              Next step, “Update macOS · Darkbloom needs macOS 27 or later. Update macOS to keep
              serving.” and <b>Open Software Update</b>.
            </p>
          ),
          prs: [1506],
          node: health(backend(running(), on26)),
        },
        {
          label: 'Update macOS, stopped',
          note: (
            <p>
              Stopped with models chosen: the headline and first step stay <b>Stopped</b> /{' '}
              <b>Start serving</b>; Update macOS follows it.
            </p>
          ),
          prs: [1506],
          node: health(backend(stopped(), on26)),
        },
        {
          label: 'Update macOS, not linked',
          note: (
            <p>
              Not linked as well: Update macOS comes before “Link this Mac”.
            </p>
          ),
          prs: [1506, 1471],
          node: health(backend(running({ linked: false }), on26)),
        },
        {
          label: 'Home: macOS notice',
          note: (
            <p>
              Home on 26.5: under the header, the same text as a notice with{' '}
              <b>Open Software Update</b> and a close button. Serving is untouched:{' '}
              <b>Stop serving</b> still works.
            </p>
          ),
          prs: [1506],
          node: home(running(), on26),
        },
        {
          label: 'Home: notice dismissed',
          note: (
            <p>
              After the close button (clicked by the play step): the notice is gone until
              Darkbloom is next opened ({code('sessionStorage')}), also on other Homes mounted
              later; This Mac's step stays.
            </p>
          ),
          prs: [1506],
          node: home(running(), on26),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const runtime = (state: DesktopStatus['state'], message?: string) =>
  health(backend(running(), { status: { state, message } }));

export const RuntimeConnection: Story = {
  name: 'This Mac: CLI connection',
  render: () => (
    <Walkthrough
      title="This Mac: CLI connection"
      intro={
        <p>
          When the desktop status isn't {code('ready')} but a snapshot was already received, the
          page stays up with its last data and readiness reports only the connection
          (<code>runtimeStep</code>): “Serving status unavailable”. Without any snapshot the app
          shows the startup screen instead (see <i>Flows › Onboarding › Returning user</i>).
        </p>
      }
      steps={[
        {
          label: 'Reconnecting',
          note: (
            <p>
              Status {code('connecting')}: pending, “Connecting to this Mac” and “Reconnecting to
              the Darkbloom CLI · The app reconnects automatically.” No button. (“Reconnecting to
              the runtime” before #1506.)
            </p>
          ),
          prs: [1506],
          node: runtime('connecting'),
        },
        {
          label: 'Installing',
          note: (
            <p>
              Status {code('installing')}: pending, “Setting up Darkbloom” and “Installing the
              Darkbloom CLI · This can take a few minutes.”, no button.
            </p>
          ),
          prs: [1506],
          node: runtime('installing'),
        },
        {
          label: 'CLI missing',
          note: (
            <p>
              Status {code('missing')}: blocked, “Setup required”, “Install the Darkbloom CLI” with{' '}
              <b>Install CLI</b> (“Install the Darkbloom runtime” / <b>Install runtime</b> before
              #1506).
            </p>
          ),
          prs: [1506],
          node: runtime('missing'),
        },
        {
          label: 'CLI error',
          note: (
            <p>
              Status {code('error')}: blocked, “Connection unavailable”, “Repair the Darkbloom CLI”
              with the status message as the detail, <b>Repair CLI</b> (<b>Repair runtime</b>{' '}
              before #1506).
            </p>
          ),
          prs: [1457, 1506],
          node: runtime('error', 'The bundled preview API did not start: Desktop API is already running'),
        },
        {
          label: 'Incompatible CLI',
          note: (
            <p>
              Status {code('incompatible')}: shown exactly like an error (“Connection unavailable”,
              “Repair the Darkbloom CLI”, <b>Repair CLI</b>); the snapshot from that CLI is not
              used. Since the #1456 follow-up the main process reports a protocol mismatch as{' '}
              {code('incompatible')} (it was a plain {code('error')}), and the startup screen says
              “Update the Darkbloom CLI to continue.” with <b>Update CLI</b> (first-run step 1
              too). This Overview step says <b>Repair CLI</b> rather than Update CLI; until #1506 it
              said “Repair the Darkbloom runtime” / <b>Repair runtime</b>.
            </p>
          ),
          prs: [1459, 1456, 1506],
          node: runtime('incompatible', 'This runtime uses protocol 2; this app needs protocol 1.'),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const cell = (node: ReactNode) => <div style={{ maxWidth: 380 }}>{node}</div>;
const fanButton = (c?: CoolingData) => <FanStatus cooling={c} onOpen={noop} />;

export const MemoryAndFans: Story = {
  name: 'Memory and fan readings',
  render: () => (
    <Walkthrough
      title="Memory and fan readings"
      intro={
        <p>
          The other two Overview cells (<code>MemoryHealth</code>, <code>FanHealth</code>) and
          Home's fan button (<code>FanStatus</code>). Each says when a reading is missing, unknown
          or out of date instead of showing zero.
        </p>
      }
      steps={[
        {
          label: 'Memory reported',
          note: <p>Running: {code('memory.active_gb')} 37.8 of 64 GB, 20 GB free to load.</p>,
          node: cell(<MemoryHealth memory={running().memory} />),
        },
        {
          label: 'Memory total only',
          note: <p>Stopped ({code('{ total_gb: 64 }')} only): “64 GB total · Reported while this Mac is serving.” (“while the provider runs” before #1501)</p>,
          prs: [1501],
          node: cell(<MemoryHealth memory={{ total_gb: 64 }} />),
        },
        {
          label: 'Memory unknown',
          note: <p>{code('total_gb: 0')} is how the runtime reports a failed probe: “Memory unknown”, not “0 GB total”.</p>,
          prs: [1465],
          node: cell(<MemoryHealth memory={{ total_gb: 0 }} />),
        },
        {
          label: 'Fans: still reading',
          note: <p>No cooling data yet: “Checking… · Reading fan sensors.”</p>,
          node: cell(<FanHealth cooling={undefined} />),
        },
        {
          label: 'Fans: spinning',
          note: <p>Two fans with RPM: “Spinning”, each fan's RPM, “macOS control”, 58°C GPU.</p>,
          node: cell(<FanHealth cooling={cooling} />),
        },
        {
          label: 'Fans: stopped',
          note: <p>Every fan at 0 RPM: “Stopped”.</p>,
          node: cell(<FanHealth cooling={{ ...cooling, fans: cooling.fans.map((fan) => ({ ...fan, rpm: 0 })) }} />),
        },
        {
          label: 'Fans: none',
          note: <p>A fanless Mac (empty {code('fans')}): “No fans · macOS manages cooling.”</p>,
          node: cell(<FanHealth cooling={{ ...cooling, fans: [] }} />),
        },
        {
          label: 'Fans: unavailable',
          note: <p>{code('cooling.error')} set: “Unavailable” with the error as detail.</p>,
          node: cell(<FanHealth cooling={{ supported: false, fans: [], mode: 'unavailable', error: 'Cooling status is unavailable.' }} />),
        },
        {
          label: 'Fans: reading five minutes old',
          note: (
            <p>
              {code('cooling.observed_at')} 300 s ago: “Unavailable · The last fan reading is out
              of date.”, with no RPM, fan glyph or GPU temperature, matching Home's fan button
              (next step, third button: “Fan status unavailable” after 60 s) and the Cooling page.
              Before #1488 this cell had no age check and showed the old RPM as current (fixed by
              #1488).
            </p>
          ),
          prs: [1488],
          node: cell(<FanHealth cooling={{ ...cooling, observed_at: now() - 300 }} />),
        },
        {
          label: 'Home fan button: on, off, hot, stale, checking',
          note: (
            <p>
              Home's chip header: “Auto fan on”; “Auto fan off” at 84°C (warning hue); a reading
              older than 60 s and an errored one both read “Fan status unavailable”; no data yet
              reads “Checking fans”. Text should stay readable in both themes.
            </p>
          ),
          prs: [1470],
          node: (
            <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
              {fanButton(cooling)}
              {fanButton({ ...cooling, enabled: false, temperature: 84 })}
              {fanButton({ ...cooling, observed_at: now() - 300 })}
              {fanButton({ ...cooling, error: 'Cooling status is unavailable.' })}
              {fanButton(undefined)}
            </div>
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

/** What a screen reader gets from the chip: its live announcement and its full summary. */
function Spoken({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [text, setText] = useState({ live: '…', summary: '…' });
  useEffect(() => {
    const read = () => {
      const stage = ref.current?.querySelector('section[aria-label$="chip activity"]');
      setText({
        live: stage?.querySelector('[aria-live="polite"]')?.textContent || '—',
        summary: stage?.querySelector(':scope > p:not([aria-live])')?.textContent || '—',
      });
    };
    read();
    const timer = setInterval(read, 1000);
    return () => clearInterval(timer);
  }, []);
  return (
    <div ref={ref}>
      <p className="sb-observed">
        Announced: “{text.live}”
        <br />
        Summary (read on demand): “{text.summary}”
      </p>
      {children}
    </div>
  );
}

const home = (state: Snapshot, extra: Partial<BackendState> = {}) => (
  <Spoken>
    <Home backend={backend(state, extra)} navigate={noop} openMachine={noop} />
  </Spoken>
);
const live = () =>
  running({
    observed_at: now(),
    activity: {
      requests: '1284',
      tokens: '512400',
      samples: [],
      sampled_at: now(),
      models: [
        { model: 'gpt-oss-20b', state: 'running', running: 2, waiting: 1 },
        { model: 'gemma-4-26b', state: 'idle', running: 0, waiting: 0 },
      ],
    },
  });

export const HomeStates: Story = {
  name: 'Home: provider state and the chip',
  render: () => (
    <Walkthrough
      title="Home: provider state and the chip"
      intro={
        <p>
          Home's header button and the chip stage follow {code('snapshot.state')}. The chip counts
          the provider as up when it is running, draining or stale; live numbers (tokens per
          second, in progress, waiting) are shown only while activity is fresh: running or
          draining, {code('activity.models')} present, {code('sampled_at')} and{' '}
          {code('observed_at')} within 10 s, and no running operation. Above each Home, the chip's
          screen-reader text as it is now. Hardware readouts need the native hardware stream,
          which Storybook doesn't provide.
        </p>
      }
      steps={[
        {
          label: 'Stopped',
          note: (
            <p>
              {code("state: 'stopped'")}: <b>Start serving</b> (opens Models), chip unpowered,
              announced “not serving”, mode “Stopped”. Starting, draining and stale no longer offer
              it (#1487). Before #1501 these read “Start providing”, “provider stopped” and
              “Provider stopped”.
            </p>
          ),
          prs: [1478, 1501],
          node: home(stopped()),
        },
        {
          label: 'Starting',
          note: (
            <p>
              {code("state: 'starting'")}: still unpowered, announced “starting to serve”. The
              header reads <b>Starting…</b>, disabled (before #1487 it offered Start providing;
              #1487 labeled it Starting provider, and #1501 shortened it).
            </p>
          ),
          prs: [1478, 1487, 1501],
          node: home(stopped({ state: 'starting' })),
        },
        {
          label: 'Serving, live activity',
          note: (
            <p>
              Running with fresh activity (sampled now): <b>Stop serving</b>, the chip powered
              with “2 in progress, 1 waiting” in the readouts. Only “live activity” is announced;
              the numbers stay in the summary. Tokens per second reads 0 because a rate needs two
              snapshots and the fixture is a single one. The data is fixed, so after 10 s it goes
              stale and the numbers disappear, as they would in the app; reload to see it again.
            </p>
          ),
          prs: [1478, 1501],
          node: home(live()),
        },
        {
          label: 'Running, activity not fresh',
          note: (
            <p>
              Running but {code('activity.sampled_at')} missing: powered, no numbers (never
              invented from old counters). Announced “waiting for live activity”; before #1487 it
              said “live activity” with a trailing space and no numbers (fixed by #1487).
            </p>
          ),
          prs: [1487],
          node: home(running()),
        },
        {
          label: 'Draining',
          note: (
            <p>
              {code("state: 'draining'")}: the chip stays powered and is announced “finishing
              current requests”. The header reads <b>Finishing requests</b>, disabled,
              as This Mac's status does. Before #1487 it offered <b>Start providing</b> (only{' '}
              {code("'running'")} counted as running) and announced “live activity” (fixed by
              #1487).
            </p>
          ),
          prs: [1487],
          node: home(running({ state: 'draining' })),
        },
        {
          label: 'Stale',
          note: (
            <p>
              {code("state: 'stale'")}: powered but no live numbers, and This Mac reads “Status
              unavailable” in the fleet list. The provider process is still up, so the header
              offers <b>Stop serving</b>, and the chip is announced “status out of date”.
              Before #1487 the header offered <b>Start providing</b> (no way to stop from Home) and
              the chip was announced as “live activity” (fixed by #1487).
            </p>
          ),
          prs: [1487],
          node: home(running({ state: 'stale' })),
        },
        {
          label: 'Not linked',
          note: (
            <p>
              {code('linked: false')} and no code yet: a <b>Link account</b> button at the bottom
              (disabled while a {code('link')} operation runs).
            </p>
          ),
          prs: [1471],
          node: home(running({ linked: false })),
        },
        {
          label: 'Link code waiting',
          note: (
            <p>
              {code('link.code')} present: the footer shows the code to enter instead of asking
              for another.
            </p>
          ),
          prs: [1471],
          node: home(
            running({
              linked: false,
              link: { url: 'https://example.invalid/link', code: 'BLOOM-7Q4K', expires_at: 1_790_000_900, state: 'pending' },
            }),
          ),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const other = (overrides: Partial<Machine>): Machine => ({
  id: 'studio',
  name: 'Mac Studio',
  chip: 'Apple M3 Ultra',
  memory_gb: 192,
  status: 'running',
  observed_at: now() - 120,
  models: ['gpt-oss-20b'],
  ...overrides,
});
const remote = (machine: Machine): Step['node'] => (
  <RemoteStatus machine={machine} presence={remotePresence(machine, now())} />
);

export const OtherMacs: Story = {
  name: 'Other Macs: view-only status',
  render: () => (
    <Walkthrough
      title="Other Macs: view-only status"
      intro={
        <p>
          My Macs › another Mac on the account (<code>RemoteStatus</code>). Presence comes from{' '}
          <code>presence.ts</code>: <i>online</i> when the account reports running/online/serving
          and the observation is under 15 minutes old, <i>stale</i> when it's older or missing,
          otherwise the reported status is named. These Macs are view only.
        </p>
      }
      steps={[
        { label: 'Online', note: <p>{code("status: 'running'")}, observed 2 minutes ago: green “Online”.</p>, node: remote(other({})) },
        {
          label: 'Not reporting',
          note: <p>Running, but last observed 40 minutes ago: amber “Not reporting · last reported Online”.</p>,
          node: remote(other({ observed_at: now() - 40 * 60 })),
        },
        {
          label: 'Never observed',
          note: <p>Running with no {code('observed_at')}: “Not reporting” and “Not observed yet”.</p>,
          prs: [1464],
          node: remote(other({ observed_at: undefined })),
        },
        { label: 'Offline', note: <p>{code("status: 'offline'")}.</p>, node: remote(other({ status: 'offline' })) },
        { label: 'Stopped', note: <p>{code("status: 'stopped'")}.</p>, prs: [1464], node: remote(other({ status: 'stopped' })) },
        { label: 'Starting', note: <p>{code("status: 'starting'")}: named, not “Offline”.</p>, prs: [1464], node: remote(other({ status: 'starting' })) },
        {
          label: 'Finishing requests',
          note: <p>{code("status: 'draining'")}.</p>,
          prs: [1464],
          node: remote(other({ status: 'draining' })),
        },
        {
          label: 'Verification needed',
          note: <p>{code("status: 'untrusted'")}.</p>,
          prs: [1464],
          node: remote(other({ status: 'untrusted' })),
        },
        {
          label: 'Unrecognized status',
          note: <p>A status this app doesn't know: “Status unavailable”, never the raw protocol word.</p>,
          prs: [1464],
          node: remote(other({ status: 'maintenance' })),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const withAccount = (account: Snapshot['account']) =>
  backendFor('after', running({ capabilities: ['account-signin', 'autopilot', 'waitlist'], account }));

export const AccountAndHeader: Story = {
  name: 'Account and the app header',
  beforeEach: () => {
    const previous = localStorage.getItem('darkbloom.onboardingComplete');
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    resetBridges({ read: (resource) => previewAPI.read(resource as never) });
    return () => {
      if (previous === null) localStorage.removeItem('darkbloom.onboardingComplete');
    };
  },
  render: () => (
    <Walkthrough
      title="Account and the app header"
      intro={
        <p>
          The sidebar's account control and the top bar's connection status. The account control
          appears only when the runtime advertises {code('account-signin')}.
        </p>
      }
      steps={[
        {
          label: 'Signed out',
          note: <p>{code('account.signed_in: false')}: “Sign in · Darkbloom account”.</p>,
          node: cell(<AccountControl backend={withAccount({ signed_in: false })} />),
        },
        {
          label: 'Signed in',
          note: <p>Signed in with an email: the address and “Signed in”.</p>,
          node: cell(<AccountControl backend={withAccount({ signed_in: true, email: 'provider@example.com' })} />),
        },
        {
          label: 'Connected (whole app)',
          note: (
            <p>
              The real {code('App')} on the app's development-preview fixtures, status{' '}
              {code('ready')}: the top bar reads “Connected to this Mac” with a green dot and the
              sidebar badge counts this Mac plus the account's others. The “Reconnecting” top bar
              (status not ready after a snapshot) needs a status push the Storybook bridge doesn't
              emit; its readiness counterpart is under <i>This Mac: CLI connection</i>.
            </p>
          ),
          node: <App />,
          height: 760,
        },
      ]}
    />
  ),
};
