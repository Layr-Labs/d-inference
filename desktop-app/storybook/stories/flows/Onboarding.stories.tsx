import { useEffect, useRef, useState, type ReactNode } from 'react';
import { ArrowRight } from 'lucide-react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { expect, userEvent, within } from 'storybook/test';
import App from '../../src/after/desktop-app/src/renderer/App';
import { Onboarding } from '../../src/after/desktop-app/src/renderer/components/Onboarding';
import { Startup } from '../../src/after/desktop-app/src/renderer/components/Startup';
import { External } from '../../src/after/desktop-app/src/renderer/components/UI';
import { OnboardingIntro, type GridState } from '../../src/after/desktop-app/src/renderer/components/onboarding/OnboardingIntro';
import { OnboardingSteps } from '../../src/after/desktop-app/src/renderer/components/onboarding/OnboardingSteps';
import { ScanStep } from '../../src/after/desktop-app/src/renderer/components/onboarding/ScanStep';
import { StartServing } from '../../src/after/desktop-app/src/renderer/components/onboarding/StartServing';
import { evaluateEligibility } from '../../src/after/desktop-app/src/renderer/components/onboarding/eligibility';
import type { ScanFrame } from '../../src/after/desktop-app/src/renderer/components/onboarding/scanScript';
import type { MacScan } from '../../src/after/desktop-app/src/renderer/components/onboarding/useMacScan';
import { previewAPI } from '../../src/after/desktop-app/src/renderer/preview';
import { withOnboardingScenario } from '../../src/after/desktop-app/src/renderer/previewEligibility';
import type { BackendState } from '../../src/after/desktop-app/src/renderer/useBackend';
import type { Action, DesktopStatus, Operation, Snapshot } from '../../src/after/desktop-app/src/shared/contracts';
import { Walkthrough, type Step } from '../support/Walkthrough';
import { bridges, resetBridges, succeeded } from '../support/bridge';
import { backendFor, eightGBMac, models, poolSnapshot, snapshot } from '../support/fixtures';

const meta: Meta = { title: 'Flows/Onboarding', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const noop = () => {};
const now = () => Math.floor(Date.now() / 1000);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const flag = 'darkbloom.onboardingComplete';

// What DesktopSnapshot.swift reports before anything is downloaded: catalog size, no memory_gb.
const freshInstall = (overrides: Partial<Snapshot> = {}) =>
  snapshot({
    models: models.map(({ memory_gb: _, ...model }) => ({
      ...model,
      downloaded: false,
      serving: false,
      loaded: false,
    })),
    ...overrides,
  });

const backend = (state: Snapshot | undefined, status: DesktopStatus = { state: 'ready' }, extra: Partial<BackendState> = {}) =>
  backendFor('after', state, { status, ...extra });

const unlinked = (overrides: Partial<Snapshot> = {}) => snapshot({ linked: false, ...overrides });
const pendingLink = (): NonNullable<Snapshot['link']> => ({
  url: 'https://example.invalid/link',
  code: 'BLOOM-7Q4K',
  expires_at: now() + 900,
  state: 'pending',
});
const linkOperation = (state: Operation['state']): Operation => ({
  id: 'link-1',
  action: 'link',
  state,
  started_at: now(),
  message: state === 'running' ? 'Waiting for approval' : '',
  cancellable: state === 'running',
});
const withoutLink = ({ link: _, ...state }: Snapshot): Snapshot => state;

/** Remove the first-run flag for one story and put it back afterwards. */
const firstLaunch = () => {
  const previous = localStorage.getItem(flag);
  localStorage.removeItem(flag);
  return () => {
    if (previous === null) localStorage.removeItem(flag);
    else localStorage.setItem(flag, previous);
  };
};

/** The step's own pane, found by the label Walkthrough gives it. */
const pane = (canvasElement: HTMLElement, label: string) =>
  within(within(canvasElement).getByRole('region', { name: label }));

function code(text: string) {
  return <code>{text}</code>;
}

// ---------------------------------------------------------------------------------------------
// A stateful stand-in for the runtime, so one pane can follow a step through several states
// (link code arriving, approval) with the real Onboarding component. Actions are recorded in
// the flow's log; `respond` says how the "runtime" reacts.

type Runtime = { state?: Snapshot; status: DesktopStatus };
type Respond = (action: Action, current: Runtime) => Runtime | undefined;
const runtimes = new Map<string, (update: (current: Runtime) => Runtime) => void>();
const runtime = (id: string) => runtimes.get(id)!;

function LiveOnboarding({ id, initial, respond }: { id: string; initial: Runtime; respond?: Respond }) {
  const [current, setCurrent] = useState(initial);
  const latest = useRef(current);
  latest.current = current;
  useEffect(() => {
    runtimes.set(id, setCurrent);
    return () => void runtimes.delete(id);
  }, [id]);
  const live = backendFor('after', current.state, {
    status: current.status,
    act: async (action) => {
      bridges.after.record(JSON.stringify(action));
      const next = respond?.(action, latest.current);
      if (next) setTimeout(() => setCurrent(next), 500);
      return true;
    },
  });
  return <Onboarding backend={live} done={() => bridges.after.record('done(): onboarding closes, Home opens')} />;
}

// The runtime's device-code link: a code arrives, Cancel cancels the running operation.
const linkRuntime: Respond = (action, current) => {
  if (!current.state) return undefined;
  if (action.action === 'link')
    return { ...current, state: { ...current.state, link: pendingLink(), operations: [linkOperation('running')] } };
  if (action.action === 'cancel')
    return { ...current, state: { ...withoutLink(current.state), operations: [linkOperation('cancelled')] } };
  return undefined;
};
// A runtime that is still asking the coordinator for a code.
const slowLink: Respond = (action, current) =>
  action.action === 'link' && current.state
    ? { ...current, state: { ...current.state, operations: [linkOperation('running')] } }
    : undefined;
const approve = (current: Runtime): Runtime => ({
  ...current,
  state: { ...withoutLink(current.state!), linked: true, operations: [linkOperation('succeeded')] },
});
const fail = (current: Runtime): Runtime => ({
  ...current,
  state: { ...withoutLink(current.state!), operations: [{ ...linkOperation('failed'), message: 'The link code expired.' }] },
});

// ---------------------------------------------------------------------------------------------
// Onboarding.tsx's own wrapper (logo, intro grid, step list with the exit, footer) around one of
// its steps, so a state that the real component passes through on a timer can be held still.
// The step bodies (ScanStep, StartServing) are the app's components, unchanged.

function Frame({ step, grid, linked = true, children }: { step: 1 | 3; grid: GridState; linked?: boolean; children: ReactNode }) {
  return (
    <div className="onboarding">
      <img src="./brand/logo.svg" alt="Darkbloom" className="onboarding-logo" />
      <div className="onboarding-layout">
        <OnboardingIntro grid={grid} />
        <section className="onboarding-form">
          <div className="onboarding-progress">
            <OnboardingSteps current={step} linked={linked} />
            <button className="text-link" onClick={noop}>
              Explore the app first <ArrowRight size={13} />
            </button>
          </div>
          <div className="onboarding-step">{children}</div>
        </section>
      </div>
      <footer>
        <span>Powered by your Mac. Built by people.</span>
        <External target="docs">Read the guide</External>
      </footer>
    </div>
  );
}

const verdict = (state: Snapshot, macos = '27.0'): ScanFrame => {
  const rows = evaluateEligibility(state, macos).checks.length;
  return { revealed: rows, resolved: rows, phase: 'verdict' };
};
const waiting: ScanFrame = { revealed: 0, resolved: 0, phase: 'waiting' };

/** The check step exactly as useMacScan would report it at `frame`. */
function ScanAt({ backend, frame, reading = false }: { backend: BackendState; frame: ScanFrame; reading?: boolean }) {
  // As useMacScan: the main process's macOS version adds a macOS check when the report has none.
  const result =
    backend.state && !reading ? evaluateEligibility(backend.state, backend.system?.macosVersion) : undefined;
  const settled = !!result && (frame.phase === 'verdict' || frame.phase === 'leaving');
  const scan: MacScan = {
    result,
    frame: result ? frame : waiting,
    finish: noop,
    settled,
    recheck: async () => {},
  };
  // Onboarding.tsx's grid: joined once an eligible verdict lands, idle when settled.
  const grid: GridState = settled && result?.verdict === 'eligible' ? 'joined' : settled ? 'idle' : 'scanning';
  return (
    <Frame step={1} grid={grid} linked={!!backend.state?.linked}>
      <ScanStep
        backend={backend}
        scan={scan}
        next={backend.state?.linked ? 'start serving' : 'link your account'}
        proceed={noop}
        explore={noop}
      />
    </Frame>
  );
}

const StartAt = ({ backend }: { backend: BackendState }) => (
  <Frame step={3} grid="joined" linked={!!backend.state?.linked}>
    <StartServing
      backend={backend}
      snapshot={backend.state!}
      link={() => bridges.after.record('link(): back to Link your account')}
      done={noop}
    />
  </Frame>
);

// ---------------------------------------------------------------------------------------------

let firstRun: Snapshot;
// The installer's progress as the main process reports it (installProgress.ts, backend.ts).
const installMessages = [
  'Installing the Darkbloom CLI…',
  'Finding the latest CLI release…',
  'Downloading the CLI… 42%',
  'Downloading the CLI… 100%',
  'Verifying the CLI’s signature…',
  'Setting up this Mac’s identity…',
  'Finishing up…',
  'CLI installed. Starting it…',
];
const notInstalled: DesktopStatus = { state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' };

/** Click through a running check: Skip, then Continue now, until `done` appears. */
async function passCheck(step: ReturnType<typeof pane>, done: RegExp) {
  for (let i = 0; i < 40; i++) {
    if (step.queryByRole('button', { name: done })) return;
    const next =
      step.queryByRole('button', { name: /Continue now/ }) ?? step.queryByRole('button', { name: /^Skip/ });
    if (next) await userEvent.click(next);
    await sleep(300);
  }
  await step.findByRole('button', { name: done }, { timeout: 8000 });
}

export const FirstRun: Story = {
  name: 'First run, end to end (live)',
  beforeEach: () => {
    const restore = firstLaunch();
    firstRun = freshInstall({ linked: false, observed_at: now() });
    resetBridges({
      // First launch after dragging the app to Applications: no CLI yet.
      status: async () => notInstalled,
      // The click starts the installer; the main process reports its progress, then connects.
      install: async () => {
        for (const message of installMessages) {
          bridges.after.pushStatus({ state: 'installing', message });
          await sleep(600);
        }
        bridges.after.pushStatus({ state: 'ready' });
      },
      read: async (resource) => {
        if (resource !== 'state') return previewAPI.read(resource as never);
        return firstRun;
      },
      act: async (action: Action) => {
        if (action.action === 'link') {
          firstRun = { ...firstRun, link: pendingLink(), operations: [linkOperation('running')] };
          setTimeout(() => bridges.after.pushState(firstRun), 500);
        }
        if (action.action === 'autopilot') firstRun = poolSnapshot({}, { observed_at: now() });
        return succeeded(action.action);
      },
    });
    return restore;
  },
  play: async ({ canvasElement }) => {
    const app = pane(canvasElement, 'The real app, from first launch to Home');
    await userEvent.click(await app.findByRole('button', { name: /Install CLI/ }, { timeout: 8000 }));
    // The check runs by itself once the CLI connects (about 3 s), then hands off to linking.
    await userEvent.click(await app.findByRole('button', { name: /Link account/ }, { timeout: 20000 }));
    await userEvent.click(await app.findByRole('button', { name: /Open link page/ }, { timeout: 8000 }));
    // Approved in the browser: the runtime reports the Mac linked, and Start follows.
    await sleep(1500);
    firstRun = { ...withoutLink(firstRun), linked: true, operations: [linkOperation('succeeded')] };
    bridges.after.pushState(firstRun);
    const start = await app.findByRole('button', { name: /Start serving with Autopilot/ }, { timeout: 15000 });
    await userEvent.click(start);
    await expect(await app.findByRole('heading', { name: 'Your contribution' }, { timeout: 8000 })).toBeTruthy();
  },
  render: () => (
    <Walkthrough
      title="First run, end to end"
      intro={
        <>
          <p>
            The user downloads the DMG, drags Darkbloom to Applications and opens it. The first
            screen is step 1, <b>Install the Darkbloom CLI</b>: nothing is installed until the user
            clicks <b>Install CLI</b>. The CLI owns the background service that serves models and
            its updates (<code>darkbloom update</code>). Then the app checks this Mac, links the
            account (an ineligible Mac stops at the check and is never asked to link; a linked
            Mac skips linking), and starts serving. Darkbloom needs macOS 27 or later. See{' '}
            <i>Install flow</i> for what macOS shows at each step.
          </p>
          <p>
            This pane is the real <code>App</code> with no{' '}
            <code>darkbloom.onboardingComplete</code> flag. The play step clicks{' '}
            <b>Install CLI</b> (the mocked installer reports the main process's progress
            messages, then connects), lets the check run and hand off to <b>Link your
            account</b>, presses <b>Link account</b> and <b>Open link page</b>, approves the link
            (the runtime reports <code>linked: true</code>), presses <b>Start serving with
            Autopilot</b>, and lands on Home. Reload to watch it again (about 20 s).
          </p>
        </>
      }
      log
      steps={[
        {
          label: 'The real app, from first launch to Home',
          note: (
            <p>
              Look for: the step list moving 1 Install CLI → 2 Check this Mac → 3 Link your account
              → 4 Start, with a check mark on each finished step; no install button while the CLI
              installs, only <b>Cancel</b>; <b>Explore the app first</b> appearing once the first
              snapshot arrives; the browser opened only by <b>Open link page</b> (one{' '}
              <code>openExternal link</code> in the log, after the click); exactly one{' '}
              <code>install</code>, one <code>link</code> and one <code>autopilot</code>.
            </p>
          ),
          prs: [1504, 1502, 1498, 1458, 1479],
          node: <App />,
          height: 820,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const installing = (message?: string): DesktopStatus => ({ state: 'installing', message });
const installStep = (status: DesktopStatus) => <Onboarding backend={backend(undefined, status)} done={noop} />;

export const InstallCli: Story = {
  name: 'Step 1: Install the Darkbloom CLI',
  play: async ({ canvasElement }) => {
    await userEvent.click(pane(canvasElement, 'First screen').getByRole('button', { name: /Install CLI/ }));
    await userEvent.click(pane(canvasElement, 'Installing: finding the release').getByRole('button', { name: /Cancel/ }));
    await userEvent.click(pane(canvasElement, 'Install failed').getByRole('button', { name: /Retry/ }));
  },
  render: () => (
    <Walkthrough
      title="Step 1: Install the Darkbloom CLI"
      intro={
        <p>
          The first onboarding screen. Every later step needs the CLI's background service, so{' '}
          <code>Onboarding</code> shows <code>RuntimeSetup</code> as step 1 until the CLI is
          installed, connected and has sent a snapshot: status <code>missing</code>,{' '}
          <code>error</code>, <code>incompatible</code> or <code>installing</code>, or no snapshot
          yet. Nothing later is reachable, and <b>Explore the app first</b> isn't offered because
          there is no app to open yet. The install starts only when the user clicks{' '}
          <b>Install CLI</b> (the main process never installs by itself); progress,{' '}
          <b>Cancel</b>, and a failure's reason with <b>Retry</b> and <b>Get help</b> follow. When
          the CLI's service connects, step 1 moves on to the check by itself. Darkbloom needs
          macOS 27 or later: the installer refuses a new install on macOS 26 or earlier (#1505),
          and below macOS 27 step 1 shows “Darkbloom needs macOS 27 or later” with{' '}
          <b>Open Software Update</b> instead of Install CLI (#1506; see <i>macOS 26 Mac</i>).
          These states are on macOS 27.0. The play step clicks <b>Install CLI</b>, <b>Cancel</b>{' '}
          and <b>Retry</b>; the log shows the native calls.
        </p>
      }
      log
      steps={[
        {
          label: 'First screen',
          note: (
            <p>
              Status {code('missing')} on first launch: “Install the Darkbloom CLI”, the lead
              (“Darkbloom runs on its command-line tool. It installs once, runs a background
              service that serves models on this Mac, and updates automatically.”), the main
              process's message, and <b>Install CLI</b>. Nothing is installed until the click.
            </p>
          ),
          prs: [1502, 1504],
          node: installStep(notInstalled),
        },
        {
          label: 'Installing: finding the release',
          note: (
            <p>
              After the click, status {code('installing')} with the installer's progress: a spinner
              with the message (one {code('role="status"')} region), and only <b>Cancel</b>{' '}
              ({code('api.cancelInstall()')}), never a second install button.
            </p>
          ),
          prs: [1504, 1502],
          node: installStep(installing('Finding the latest CLI release…')),
        },
        {
          label: 'Installing: download progress',
          note: (
            <p>
              The installer's curl progress in plain words ({code('installProgress.ts')}):
              “Downloading the CLI… 42%”. Then, in order: “Verifying the CLI’s signature…”,
              “Setting up this Mac’s identity…”, “Finishing up…”, “CLI installed. Starting it…”.
            </p>
          ),
          prs: [1504],
          node: installStep(installing('Downloading the CLI… 42%')),
        },
        {
          label: 'Installing, no message yet',
          note: <p>Status {code('installing')} without a message: “Installing the Darkbloom CLI…”.</p>,
          prs: [1504],
          node: installStep(installing()),
        },
        {
          label: 'Install failed',
          note: (
            <p>
              {code('{ state: "missing", installFailed: true }')}: “Couldn’t install the CLI while
              …” with the step that failed and the installer's own ✗ reason. The reason stays on
              screen (it used to be overwritten by the {code('missing')} text within 5 s), with{' '}
              <b>Retry</b> and <b>Get help</b> (opens the guide).
            </p>
          ),
          prs: [1504, 1503],
          node: installStep({
            state: 'missing',
            installFailed: true,
            message:
              'Couldn’t install the CLI while downloading it: Bundle hash mismatch — refusing to install possibly-tampered binary.',
          }),
        },
        {
          label: 'Install cancelled',
          note: (
            <p>
              After <b>Cancel</b>: status {code('missing')}, “CLI install cancelled.” and{' '}
              <b>Install CLI</b> again (a cancel isn't a failure, so no Retry or Get help).
            </p>
          ),
          prs: [1504],
          node: installStep({ state: 'missing', message: 'CLI install cancelled.' }),
        },
        {
          label: 'CLI failed to start',
          note: (
            <p>
              Status {code('error')} with the main process's message: <b>Repair CLI</b> (the same
              installer action).
            </p>
          ),
          prs: [1502, 1457],
          node: installStep({ state: 'error', message: 'Could not connect to the Darkbloom CLI. Update or repair it.' }),
        },
        {
          label: 'Incompatible CLI',
          note: (
            <p>
              Status {code('incompatible')} (the installed CLI speaks another protocol; the main
              process drops the connection): <b>Update CLI</b>.
            </p>
          ),
          prs: [1502, 1459, 1456],
          node: installStep({
            state: 'incompatible',
            message: 'The installed Darkbloom CLI is not compatible with this version of the app. Update the CLI.',
          }),
        },
        {
          label: 'Connecting',
          note: (
            <p>
              Status {code('connecting')}, no snapshot yet: “Connecting to the Darkbloom CLI…” with
              a spinner and no button. When the CLI is already installed, step 1 is skipped as soon
              as its service answers.
            </p>
          ),
          prs: [1502],
          node: installStep({ state: 'connecting' }),
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const eligible = withOnboardingScenario(snapshot(), 'eligible');

export const CheckThisMac: Story = {
  name: 'Step 2: Check this Mac',
  render: () => (
    <Walkthrough
      title="Step 2: Check this Mac"
      intro={
        <p>
          Once the CLI is installed and connected, onboarding opens on a welcome view with step 2
          current, and <b>Start</b> runs the eligibility check (straight away when the install
          step was just shown). It decides from the first snapshot it sees, reveals one check at a
          time over about three seconds, holds an eligible verdict for one second and moves on by
          itself: to <b>Link your account</b>, or to Start on a linked Mac. An ineligible Mac
          stops here and is never asked to link. Steps 3–6 hold the check at one frame (the app's{' '}
          <code>ScanStep</code> with the frame <code>useMacScan</code> would report). The checks
          come from <code>snapshot.eligibility</code> when the runtime reports it, otherwise they
          are derived from <code>machine</code> and <code>models</code>{' '}
          (<code>eligibility.ts</code>). Either way, when the report has no <code>macos</code>{' '}
          check, one is added from the version the main process reads (#1506): “macOS 27.0” here;
          below 27 it fails (see <i>macOS 26 Mac</i>).
        </p>
      }
      steps={[
        {
          label: 'Welcome, not linked',
          note: (
            <p>
              Ready with an unlinked snapshot: 1 Install CLI is checked, 2 Check this Mac is
              current. The copy says the check comes first, then linking. <b>Explore the app
              first</b> sits beside the steps on every step from here on.
            </p>
          ),
          prs: [1502],
          node: <Onboarding backend={backend(unlinked())} done={noop} />,
        },
        {
          label: 'Welcome, already linked',
          note: (
            <p>
              {code('linked: true')}: the same welcome, with “That takes a few seconds.” After the
              check, onboarding skips linking and goes to Start.
            </p>
          ),
          prs: [1502],
          node: <Onboarding backend={backend(snapshot())} done={noop} />,
        },
        {
          label: 'Reading this Mac (Check again)',
          note: (
            <p>
              While a new read runs after <b>Check again</b>: “Checking this Mac…”, placeholder
              rows, caption <i>Reading this Mac…</i>, and no Skip link yet.
            </p>
          ),
          node: <ScanAt backend={backend(eligible)} frame={waiting} reading />,
        },
        {
          label: 'Checking requirements',
          note: (
            <p>
              Mid-scan: two of the runtime's five checks have a result, the third shows its value
              with a spinner, the rest are placeholders. Caption <i>Checking requirements…</i>,
              a <b>Skip</b> link, and the grid on the left pulses.
            </p>
          ),
          node: <ScanAt backend={backend(eligible)} frame={{ revealed: 3, resolved: 2, phase: 'scanning' }} />,
        },
        {
          label: 'Eligible, not linked',
          note: (
            <p>
              <code>snapshot.eligibility.eligible</code> is true and every check is{' '}
              <code>ok: true</code>: “This Mac is eligible.”, a check mark on the card, the grid
              lights this Mac's cell, and a countdown to <b>Next: link your account</b> with{' '}
              <b>Continue now</b> (a linked Mac reads <b>Next: start serving</b>).
            </p>
          ),
          prs: [1502],
          node: <ScanAt backend={backend({ ...eligible, linked: false })} frame={verdict(eligible)} />,
        },
        {
          label: 'Eligible on a fresh install (derived checks)',
          note: (
            <p>
              A runtime that doesn't report <code>eligibility</code>, before anything is
              downloaded: models carry only <code>size_gb</code>. The memory check compares 64 GB
              with the smallest catalog size, so a capable Mac is confirmed instead of reading
              “We couldn't confirm everything”. The macOS row comes from the app (#1506). (Linked,
              so the next step is Start.)
            </p>
          ),
          prs: [1458, 1506],
          node: <ScanAt backend={backend(freshInstall())} frame={verdict(freshInstall())} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const ready: DesktopStatus = { state: 'ready' };
/** Start from the welcome view and pass the check, which leads an unlinked Mac to linking. */
const toLinkStep = async (step: ReturnType<typeof pane>) => {
  await userEvent.click(await step.findByRole('button', { name: /^Start/ }));
  await passCheck(step, /Link account/);
};

export const LinkYourAccount: Story = {
  name: 'Step 3: Link your account',
  play: async ({ canvasElement }) => {
    const open = async (label: string) => {
      const step = pane(canvasElement, label);
      await toLinkStep(step);
      return step;
    };
    await open('Link your account');
    const getting = await open('Getting a link code');
    await userEvent.click(await getting.findByRole('button', { name: /Link account/ }));
    const shown = await open('Code shown');
    await userEvent.click(await shown.findByRole('button', { name: /Link account/ }));
    await shown.findByText('BLOOM-7Q4K');

    const opened = await open('Open link page, then approval');
    await userEvent.click(await opened.findByRole('button', { name: /Link account/ }));
    await userEvent.click(await opened.findByRole('button', { name: /Open link page/ }));
    await sleep(800);
    runtime('approved')(approve);
    await opened.findByRole('heading', { name: /Ready to serve/ });

    const cancel = await open('Cancel');
    await userEvent.click(await cancel.findByRole('button', { name: /Link account/ }));
    await userEvent.click(await cancel.findByRole('button', { name: 'Cancel' }));
    await cancel.findByRole('button', { name: /Link account/ });

    const failed = await open('Link didn’t finish');
    await userEvent.click(await failed.findByRole('button', { name: /Link account/ }));
    await failed.findByText('BLOOM-7Q4K');
    runtime('failed')(fail);
    await failed.findByText(/Linking didn’t finish/);
  },
  render: () => (
    <Walkthrough
      title="Step 3: Link your account"
      intro={
        <p>
          Earnings go to the account, and serving needs it. Linking comes after the check passes
          (#1502): an ineligible Mac is never asked to link, and an already linked Mac skips this
          step. <code>LinkStep</code> explains why; <b>Link account</b> sends the runtime's
          device-code <code>link</code> action (<code>useAccountLink</code>), and the panel shows
          the code. The browser opens only from <b>Open link page</b>: the app never calls{' '}
          <code>openExternal</code> before that, and since #1498 the native <code>link</code>{' '}
          action no longer opens the browser by itself either. Once linked, onboarding goes on to
          Start without checking again. Each pane is the real <code>Onboarding</code> on a small
          stand-in runtime; the play step presses <b>Start</b>, passes the check (Skip, Continue
          now) and clicks through each state.
        </p>
      }
      log
      steps={[
        {
          label: 'Link your account',
          note: (
            <p>
              After the check: 1 and 2 are checked, 3 Link your account is current. “Link your
              account.”, why (earnings from this Mac go to your account; then start serving), and{' '}
              <b>Link account</b> (disabled while the app is busy).
            </p>
          ),
          prs: [1502],
          node: <LiveOnboarding id="intro" initial={{ state: unlinked(), status: ready }} respond={linkRuntime} />,
        },
        {
          label: 'Getting a link code',
          note: (
            <p>
              After <b>Link account</b>, before the runtime reports {code('snapshot.link')}: a
              placeholder for the code, “Getting a link code…”, and <b>Cancel</b>.
            </p>
          ),
          prs: [1502, 1499],
          node: <LiveOnboarding id="slow" initial={{ state: unlinked(), status: ready }} respond={slowLink} />,
        },
        {
          label: 'Code shown',
          note: (
            <p>
              {code('snapshot.link.code')} arrived: the code in large type, “Open the link page and
              enter this code. Then approve this Mac.”, <b>Open link page</b>, “Waiting for
              approval…”, and <b>Cancel</b> as a secondary button (it was a small text link before
              #1499).
            </p>
          ),
          prs: [1502, 1499],
          node: <LiveOnboarding id="shown" initial={{ state: unlinked(), status: ready }} respond={linkRuntime} />,
        },
        {
          label: 'Open link page, then approval',
          note: (
            <p>
              <b>Open link page</b> is the only thing that opens the browser (
              {code('openExternal link')} in the log). Once the runtime reports{' '}
              {code('linked: true')}, step 3 gets its check mark and onboarding moves on to{' '}
              <b>Ready to serve</b> by itself.
            </p>
          ),
          prs: [1502, 1498],
          node: <LiveOnboarding id="approved" initial={{ state: unlinked(), status: ready }} respond={linkRuntime} />,
        },
        {
          label: 'Cancel',
          note: (
            <p>
              <b>Cancel</b> sends {code('cancel')} for the running {code('link')} operation and
              returns to <b>Link account</b>.
            </p>
          ),
          prs: [1502, 1499],
          node: <LiveOnboarding id="cancel" initial={{ state: unlinked(), status: ready }} respond={linkRuntime} />,
        },
        {
          label: 'Link didn’t finish',
          note: (
            <p>
              The {code('link')} operation ends {code('failed')} (here: the code expired): “Linking
              didn’t finish. Link again to get a new code.” and <b>Link account</b> again.
            </p>
          ),
          prs: [1502],
          node: <LiveOnboarding id="failed" initial={{ state: unlinked(), status: ready }} respond={linkRuntime} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const ineligible = withOnboardingScenario(snapshot(), 'ineligible');
let waitlistReply: 'ok' | 'unsupported' = 'ok';

export const NotEligible: Story = {
  name: 'Not eligible, and the waitlist',
  beforeEach: () =>
    resetBridges({
      act: async (action) => {
        if (action.action === 'waitlist' && waitlistReply === 'unsupported')
          throw new Error('Unknown action: waitlist');
        return succeeded(action.action);
      },
    }),
  play: async ({ canvasElement }) => {
    const join = async (label: string, email: string, reply: typeof waitlistReply) => {
      const step = pane(canvasElement, label);
      await userEvent.type(step.getByRole('textbox', { name: 'Email address' }), email);
      waitlistReply = reply;
      await userEvent.click(step.getByRole('button', { name: /Join the waitlist/ }));
    };
    await join('Waitlist: invalid address', 'name@example', 'ok');
    await join('Waitlist: joined', 'provider@example.com', 'ok');
    await join('Waitlist: runtime without sign-ups', 'provider@example.com', 'unsupported');
    await pane(canvasElement, 'Waitlist: runtime without sign-ups').findByRole('alert');
    waitlistReply = 'ok';
  },
  render: () => (
    <Walkthrough
      title="Not eligible, and the waitlist"
      intro={
        <p>
          Any check with <code>ok: false</code> makes the verdict <i>ineligible</i>. The check
          stays on its verdict (no hand-off), offers the waitlist when the runtime advertises the{' '}
          <code>waitlist</code> capability (or reports no capabilities), plus <b>Check again</b>{' '}
          and <b>Open dashboard</b> (the same exit as <b>Explore the app first</b>). An
          ineligible Mac stops here and is never asked to link (#1502). A Mac below macOS 27 fails
          the <code>macos</code> check and also gets <b>Open Software Update</b> (#1506; see{' '}
          <i>macOS 26 Mac</i>). Steps
          3–5 are typed and submitted by the play step; the log shows the <code>waitlist</code>{' '}
          actions sent.
        </p>
      }
      log
      steps={[
        {
          label: 'Not eligible (runtime-reported checks)',
          note: (
            <p>
              <code>snapshot.eligibility</code> from the runtime: an 8 GB M1 MacBook Air whose
              memory check failed. The failed row explains why; caption <i>1 requirement not
              met</i>; the grid stays idle.
            </p>
          ),
          node: <ScanAt backend={backend(ineligible)} frame={verdict(ineligible)} />,
        },
        {
          label: 'Not eligible (derived from the models)',
          note: (
            <p>
              No <code>eligibility</code> in the snapshot (<code>eightGBMac</code>): the only
              catalog model is <code>eligible: false</code> and needs 16.4 GB, more than the 8 GB
              reported, so the derived memory check fails with the measured sizes in its detail.
            </p>
          ),
          prs: [1458],
          node: <ScanAt backend={backend(eightGBMac())} frame={verdict(eightGBMac())} />,
        },
        {
          label: 'Waitlist: invalid address',
          note: <p>“name@example” is rejected locally with an inline alert; nothing is sent.</p>,
          node: <ScanAt backend={backend(ineligible)} frame={verdict(ineligible)} />,
        },
        {
          label: 'Waitlist: joined',
          note: (
            <p>
              The <code>waitlist</code> action (with the failed check ids as{' '}
              <code>reasons</code>) succeeded: the form is replaced by a confirmation naming the
              address. The waitlist box should fit the column without overflowing.
            </p>
          ),
          prs: [1475],
          node: <ScanAt backend={backend(ineligible)} frame={verdict(ineligible)} />,
        },
        {
          label: 'Waitlist: runtime without sign-ups',
          note: (
            <p>
              The runtime rejects the action by name (“Unknown action”): the form stays, says this
              version doesn't support sign-ups yet, and the button becomes <b>Try again</b>.
            </p>
          ),
          node: <ScanAt backend={backend(ineligible)} frame={verdict(ineligible)} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const catalogNotLoaded = withOnboardingScenario(snapshot(), 'unknown');
const undetected = snapshot({
  machine: { ...snapshot().machine, chip: '', memory_gb: 0 },
  memory: { total_gb: 0 },
});

export const CouldNotConfirm: Story = {
  name: 'Couldn’t confirm everything',
  render: () => (
    <Walkthrough
      title="Couldn’t confirm everything"
      intro={
        <p>
          When no check failed but at least one is unevaluated (<code>ok: null</code>), the
          verdict is <i>unknown</i>. Setup can continue (<b>Continue setup</b>) because the runtime
          checks that each model fits before it loads it.
        </p>
      }
      steps={[
        {
          label: 'Catalog not loaded yet',
          note: (
            <p>
              A fresh install whose runtime hasn't loaded the model catalog: <code>models</code> is
              empty and there is no <code>eligibility</code>, so Apple silicon passes but the
              memory row reads “The runtime didn't report how much memory its models need.”
              Caption <i>1 requirement couldn't be checked</i>.
            </p>
          ),
          prs: [1458],
          node: <ScanAt backend={backend(catalogNotLoaded)} frame={verdict(catalogNotLoaded)} />,
        },
        {
          label: 'Hardware not detected',
          note: (
            <p>
              <code>machine.memory_gb</code> is 0 and the chip is blank, which is how the runtime
              reports a failed hardware probe. Both rows are unevaluated (not failed), each with
              its own reason.
            </p>
          ),
          node: <ScanAt backend={backend(undetected)} frame={verdict(undetected)} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const macos26 = '26.5';
const on26 = { system: { macosVersion: macos26 } };
const olderMac = unlinked();

export const Macos26: Story = {
  name: 'macOS 26 Mac',
  beforeEach: () => {
    const restore = firstLaunch();
    resetBridges({
      macosVersion: macos26,
      status: async () => notInstalled,
      read: async (resource) => (resource === 'state' ? Promise.reject(new Error('No CLI')) : previewAPI.read(resource as never)),
    });
    return restore;
  },
  play: async ({ canvasElement }) => {
    await userEvent.click(pane(canvasElement, 'First screen, no CLI').getByRole('button', { name: /Open Software Update/ }));
    await userEvent.click(
      pane(canvasElement, 'Check this Mac fails on macOS').getByRole('button', { name: /Open Software Update/ }),
    );
    await pane(canvasElement, 'The real app on macOS 26.5').findByRole('heading', { name: /needs macOS 27/ }, { timeout: 8000 });
  },
  render: () => (
    <Walkthrough
      title="macOS 26 Mac"
      intro={
        <>
          <p>
            Darkbloom accepts new providers only on macOS 27 or later (#1506, with the installer's
            own gate in #1505). The app asks the main process for the version once (
            <code>api.system()</code> → <code>{'{ macosVersion }'}</code>, here{' '}
            <code>26.5</code>; the dev preview takes <code>?preview&amp;macos=26.5</code>). A new
            Mac below 27 is stopped before anything installs and pointed at Software Update. A Mac
            that already has the CLI is an existing provider: it isn't blocked, it is prompted to
            update (This Mac and Home: <i>Flows › Status checks › This Mac: macOS 26 Mac</i>). An
            unknown version is never treated as too old.
          </p>
          <p>
            The play step clicks <b>Open Software Update</b> in steps 1 and 2 (the log shows{' '}
            <code>openSoftwareUpdate</code>, which opens System Settings › Software Update from a
            fixed URL in the main process).
          </p>
        </>
      }
      log
      steps={[
        {
          label: 'First screen, no CLI',
          note: (
            <p>
              Status {code('missing')} on macOS 26.5, first run: “Darkbloom needs macOS 27 or
              later”, “New Macs can join Darkbloom on macOS 27 or later. This Mac runs macOS 26.5.
              Update macOS, then reopen Darkbloom.” and <b>Open Software Update</b>. No Install
              CLI, so the installer (which would refuse) never runs. The step list stays at 1;
              there is no snapshot, so no <b>Explore the app first</b>.
            </p>
          ),
          prs: [1506],
          node: <Onboarding backend={backend(undefined, notInstalled, on26)} done={noop} />,
        },
        {
          label: 'Check this Mac fails on macOS',
          note: (
            <p>
              A Mac on 26.5 that already has the CLI (installed from the terminal, say) reaches
              the check. With no {code('macos')} check in the report, the app adds one from the
              version: “macOS 26.5”, failed, “Darkbloom needs macOS 27 or later for new
              providers. Update macOS in Software Update.” The verdict is ineligible (never asked
              to link), and <b>Open Software Update</b> comes before the waitlist.
            </p>
          ),
          prs: [1506],
          node: <ScanAt backend={backend(olderMac, undefined, on26)} frame={verdict(olderMac, macos26)} />,
        },
        {
          label: 'CLI installed but broken (not gated)',
          note: (
            <p>
              Status {code('error')} on 26.5: the CLI is there, so this is an existing provider;
              step 1 offers <b>Repair CLI</b> as on macOS 27. Only {code('missing')} on a first run
              is gated.
            </p>
          ),
          prs: [1506],
          node: (
            <Onboarding
              backend={backend(undefined, { state: 'error', message: 'Could not connect to the Darkbloom CLI. Update or repair it.' }, on26)}
              done={noop}
            />
          ),
        },
        {
          label: 'Returning user reinstalling (not gated)',
          note: (
            <p>
              {code('darkbloom.onboardingComplete')} set and the CLI gone, on 26.5: the startup
              screen's “Reinstall the Darkbloom CLI to continue.” with <b>Install CLI</b>, unchanged.
              The installer lets an existing provider reinstall (#1505).
            </p>
          ),
          prs: [1506, 1456],
          node: <Startup backend={backend(undefined, notInstalled, on26)} />,
        },
        {
          label: 'macOS version unknown',
          note: (
            <p>
              {code("macosVersion: ''")} (unreadable, or a non-Mac development build): never
              guessed to be too old, so step 1 is <b>Install CLI</b> and the check adds no macOS
              row.
            </p>
          ),
          prs: [1506],
          node: <Onboarding backend={backend(undefined, notInstalled, { system: { macosVersion: '' } })} done={noop} />,
        },
        {
          label: 'The real app on macOS 26.5',
          note: (
            <p>
              The real <code>App</code> on first launch with no CLI; the mocked main process
              reports macOS 26.5. It opens on the macOS requirement, not Install CLI.
            </p>
          ),
          prs: [1506],
          node: <App />,
          height: 760,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const network = {
  model_earnings: {
    window: '7d' as const,
    as_of: new Date().toISOString(),
    models: [
      { id: 'gpt-oss-20b', earnings_micro_usd: '4820000' },
      { id: 'qwen-3.5-9b', earnings_micro_usd: '1960000' },
    ],
  },
};
const startOp = {
  id: 'autopilot-running',
  action: 'autopilot' as const,
  state: 'running' as const,
  started_at: 1_790_000_000,
  message: 'Loading GPT-OSS 20B into memory',
  cancellable: true,
};
// Replies of the mocked runtime to the Autopilot start, consumed in click order.
const startReplies: ('hang' | 'unsupported' | 'fail')[] = [];

export const StartServingStep: Story = {
  name: 'Step 4: Start serving',
  beforeEach: () => {
    startReplies.length = 0;
    resetBridges({
      act: (action) => {
        const reply = startReplies.shift();
        if (reply === 'hang') return new Promise(() => {});
        if (reply === 'unsupported') return Promise.reject(new Error('Unknown action: autopilot'));
        if (reply === 'fail')
          return Promise.reject(new Error('Not enough free disk space to download Qwen 3.5 9B.'));
        return Promise.resolve(succeeded(action.action));
      },
    });
  },
  play: async ({ canvasElement }) => {
    const step = (label: string) => pane(canvasElement, label);
    await userEvent.click(step('Advanced options').getByRole('button', { name: 'Advanced' }));
    await userEvent.click(
      step('Ready to serve (not linked)').getByRole('button', { name: /Start serving with Autopilot/ }),
    );
    for (const [label, reply] of [
      ['Starting', 'hang'],
      ['Runtime without Autopilot', 'unsupported'],
      ['Start failed', 'fail'],
    ] as const) {
      startReplies.push(reply);
      await userEvent.click(step(label).getByRole('button', { name: /Start serving with Autopilot/ }));
    }
    await step('Runtime without Autopilot').findByText(/Autopilot isn’t available/);
    await step('Start failed').findByText(/Not enough free disk space/);
  },
  render: () => (
    <Walkthrough
      title="Step 4: Start serving"
      intro={
        <p>
          The last step (<code>StartServing</code>). By default it starts Autopilot with the
          starting model (the first downloaded eligible model, else the smallest eligible one).
          It no longer links inline: a start on an unlinked Mac goes back to Link your account, and after
          linking returns here without checking again. Onboarding always sets up serving the
          network; the local-only choice (“How this Mac is used”) was removed from onboarding by
          #1502 (local models stay available in the app). Steps marked “after a click” are pressed
          by the play step; the log shows what was sent.
        </p>
      }
      log
      steps={[
        {
          label: 'Ready to serve (linked)',
          note: (
            <p>
              <code>linked: true</code>, Autopilot available (<code>capabilities</code> absent).
              The summary names this Mac (chip, memory), what starts (“Starts with GPT-OSS 20B,
              already on this Mac.”), how Autopilot manages memory, the update setting, and how to
              stop. Below the button: “Your Darkbloom account is linked.”
            </p>
          ),
          prs: [1477],
          node: <StartAt backend={backend(snapshot())} />,
        },
        {
          label: 'Ready to serve (not linked)',
          note: (
            <p>
              <code>linked: false</code> (for example, the account was unlinked during setup): the
              line under the button reads “Link your Darkbloom account first. Serving needs it.”
              After a click, nothing is sent; onboarding returns to Link your account (the log shows the{' '}
              <code>link()</code> callback).
            </p>
          ),
          prs: [1502],
          node: <StartAt backend={backend(unlinked())} />,
        },
        {
          label: 'Recommended models',
          note: (
            <p>
              With fresh 7-day network earnings (<code>network.model_earnings</code>, under five
              minutes old), Autopilot with nothing kept in memory offers up to three compatible
              earners instead of the summary. Both are preselected; the button says whether it
              downloads first.
            </p>
          ),
          node: <StartAt backend={backend(snapshot(), undefined, { network })} />,
        },
        {
          label: 'Recommended models (not linked)',
          note: (
            <p>
              The same list on an unlinked Mac labels its button <b>Link this Mac &amp; start
              Autopilot</b> (#1499); in onboarding the click also goes back to Link your account.
            </p>
          ),
          prs: [1499],
          node: <StartAt backend={backend(unlinked(), undefined, { network })} />,
        },
        {
          label: 'Advanced options',
          note: (
            <p>
              After a click on <b>Advanced</b>: only “Keep a model always on” with every model
              (models this Mac can't run are disabled). “How this Mac is used” (contribute or use
              models locally) is gone (#1502). Choosing models adds a summary such as “2 kept in
              memory · at least 22.5 GB of 64 GB memory”; over the runtime's{' '}
              <code>max_model_slots</code> it says “That’s more models than this Mac keeps in
              memory at once” instead of blaming memory (#1489).
            </p>
          ),
          prs: [1502, 1477, 1489],
          node: <StartAt backend={backend(snapshot())} />,
        },
        {
          label: 'Runtime without Autopilot',
          note: (
            <p>
              After a click, the runtime rejected <code>autopilot</code> by name: a notice explains
              Autopilot isn't available, the starting model is chosen for you and the button
              becomes a plain <b>Start serving</b> (method <i>manual</i>).
            </p>
          ),
          node: <StartAt backend={backend(snapshot())} />,
        },
        {
          label: 'Manual-only runtime',
          note: (
            <p>
              <code>capabilities</code> without <code>autopilot</code>: the step opens in manual
              mode with the starting model already chosen (“Serves GPT-OSS 20B”). No notice; the
              runtime never offered Autopilot.
            </p>
          ),
          node: <StartAt backend={backend(snapshot({ capabilities: ['waitlist'] }))} />,
        },
        {
          label: 'Starting',
          note: (
            <p>
              After a click, while the <code>autopilot</code> operation runs: the button spins
              (“Starting…”) and the line under it shows the running operation's message. (The
              fixture snapshot already contains that running operation, since it can't update
              after the click.)
            </p>
          ),
          node: <StartAt backend={backend(snapshot({ operations: [startOp] }))} />,
        },
        {
          label: 'Start failed',
          note: (
            <p>
              After a click, the operation failed with a message: the notice shows it and the
              button is enabled again.
            </p>
          ),
          node: <StartAt backend={backend(snapshot())} />,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

let exploreState: Snapshot;

export const ExploreFirst: Story = {
  name: 'Explore the app first',
  beforeEach: () => {
    const restore = firstLaunch();
    exploreState = unlinked({ observed_at: now() });
    resetBridges({
      status: async () => ({ state: 'ready' }),
      read: async (resource) => (resource === 'state' ? exploreState : previewAPI.read(resource as never)),
      act: async (action: Action) => {
        if (action.action === 'link') {
          exploreState = { ...exploreState, link: pendingLink(), operations: [linkOperation('running')] };
          setTimeout(() => bridges.after.pushState(exploreState), 300);
        }
        if (action.action === 'cancel') {
          exploreState = { ...withoutLink(exploreState), operations: [linkOperation('cancelled')] };
          setTimeout(() => bridges.after.pushState(exploreState), 300);
        }
        return succeeded(action.action);
      },
    });
    return restore;
  },
  play: async ({ canvasElement }) => {
    const app = pane(canvasElement, 'Leaving mid-link (the real app)');
    await userEvent.click(await app.findByRole('button', { name: /^Start/ }, { timeout: 8000 }));
    await passCheck(app, /Link account/);
    await userEvent.click(app.getByRole('button', { name: /Link account/ }));
    await app.findByText('BLOOM-7Q4K', {}, { timeout: 5000 });
    await userEvent.click(app.getByRole('button', { name: /Explore the app first/ }));
    await expect(await app.findByRole('heading', { name: 'Your contribution' }, { timeout: 8000 })).toBeTruthy();
  },
  render: () => (
    <Walkthrough
      title="Explore the app first"
      intro={
        <p>
          Before #1502 the only way out of onboarding was <b>Explore the app first</b> on the last
          step (plus <b>Open dashboard</b> on an ineligible or unconfirmed check). It now sits
          beside the step list on every step, as soon as the CLI's service has sent a snapshot (before
          that there is no app to open). Leaving cancels a link in progress, sets{' '}
          <code>darkbloom.onboardingComplete</code> and opens Home; next launch shows the
          returning-user startup screen, not onboarding.
        </p>
      }
      log
      steps={[
        {
          label: 'No exit before a snapshot',
          note: (
            <p>
              Step 1 while the CLI installs: no <b>Explore the app first</b>, because there is
              no dashboard to open yet.
            </p>
          ),
          prs: [1502],
          node: installStep(installing('Downloading the CLI… 42%')),
        },
        {
          label: 'Exit on every later step',
          note: (
            <p>
              The welcome view with a snapshot: the link sits at the right of the step list (it
              wraps under the steps in a narrow window).
            </p>
          ),
          prs: [1502],
          node: <Onboarding backend={backend(unlinked())} done={noop} />,
        },
        {
          label: 'Leaving mid-link (the real app)',
          note: (
            <p>
              The real <code>App</code> on first launch. The play step presses <b>Start</b>, passes
              the check, presses <b>Link account</b>, waits for the code, then <b>Explore the app
              first</b>: the log
              shows {code('cancel')} for the running {code('link')} operation, and Home opens.
            </p>
          ),
          prs: [1502],
          node: <App />,
          height: 760,
        },
      ]}
    />
  ),
};

// ---------------------------------------------------------------------------------------------

const status = (state: DesktopStatus['state'], message?: string): DesktopStatus => ({ state, message });
const startup = (s: DesktopStatus): Step['node'] => <Startup backend={backend(undefined, s)} />;

export const ReturningUser: Story = {
  name: 'Returning user: cold launch',
  render: () => (
    <Walkthrough
      title="Returning user: cold launch"
      intro={
        <p>
          With <code>darkbloom.onboardingComplete</code> set, <code>App</code> renders{' '}
          <code>Startup</code> until the first snapshot arrives, never first-run onboarding. It
          shows the connection status, or <code>RuntimeSetup</code> in its returning-user wording
          when the status is <code>missing</code>, <code>error</code> or{' '}
          <code>incompatible</code>, in CLI terms like first-run step 1. The dashboard replaces it as
          soon as a snapshot arrives.
        </p>
      }
      steps={[
        {
          label: 'Connecting',
          note: (
            <p>
              Status <code>connecting</code>, no message: the brand screen with “Connecting to this
              Mac…” (a polite status region). No Welcome, no Start button.
            </p>
          ),
          prs: [1456],
          node: startup(status('connecting')),
        },
        {
          label: 'Installing (returning user)',
          note: (
            <p>
              Status <code>installing</code> with the installer's progress message, which replaces
              the connecting text (no Cancel on this screen).
            </p>
          ),
          prs: [1456, 1504],
          node: startup(status('installing', 'Downloading the CLI… 42%')),
        },
        {
          label: 'CLI not installed',
          note: (
            <p>
              Status <code>missing</code>: straight to “Reinstall the Darkbloom CLI to continue.”
              (“The Darkbloom CLI is no longer installed on this Mac.”) with <b>Install CLI</b>.
              Before the #1456 follow-up this reused first-run copy, “Install Darkbloom to check
              this Mac.”; the follow-up said “Reinstall Darkbloom…” with <b>Reinstall runtime</b>,
              and #1502/#1504 moved it to CLI terms.
            </p>
          ),
          prs: [1456, 1502],
          node: startup(status('missing', 'Install the Darkbloom CLI to connect this Mac.')),
        },
        {
          label: 'Reinstall failed',
          note: (
            <p>
              {code('installFailed: true')} after a failed install: the reason, <b>Retry</b>{' '}
              instead of Reinstall, and <b>Get help</b>.
            </p>
          ),
          prs: [1504, 1503],
          node: startup({
            state: 'missing',
            installFailed: true,
            message: 'Couldn’t install the CLI while verifying its signature: Signature check failed.',
          }),
        },
        {
          label: 'CLI unreachable',
          note: (
            <p>
              Status <code>error</code>: “Darkbloom couldn’t start.” (“The app couldn’t start or
              connect to the Darkbloom CLI on this Mac. Repair it to continue.”) with the error
              line and <b>Repair CLI</b>. Before the #1456 follow-up it said “We couldn't check
              this Mac.”, although a returning user has no check to run.
            </p>
          ),
          prs: [1456, 1457, 1502],
          node: startup(
            status('error', 'The bundled preview API did not start: Desktop API is already running'),
          ),
        },
        {
          label: 'Incompatible CLI',
          note: (
            <p>
              Status <code>incompatible</code>: “Update the Darkbloom CLI to continue.” with{' '}
              <b>Update CLI</b> (the same installer action); the app stays disconnected instead of
              showing the incompatible CLI's data. Before the #1456 follow-up this read like an
              unreachable runtime with <b>Repair runtime</b>, and the main process reported a
              protocol mismatch as a plain <code>error</code>.
            </p>
          ),
          prs: [1456, 1459, 1502],
          node: startup(
            status('incompatible', 'The installed Darkbloom CLI is not compatible with this version of the app. Update the CLI.'),
          ),
        },
      ]}
    />
  ),
};
