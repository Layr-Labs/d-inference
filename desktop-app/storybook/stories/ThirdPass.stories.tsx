import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import AppBefore from '../src/before/desktop-app/src/renderer/App';
import AppAfter from '../src/after/desktop-app/src/renderer/App';
import { Home as HomeBefore } from '../src/before/desktop-app/src/renderer/features/Home';
import { Home as HomeAfter } from '../src/after/desktop-app/src/renderer/features/Home';
import { FanHealth as FanHealthBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/FanHealth';
import { FanHealth as FanHealthAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/FanHealth';
import { FanStatus as FanStatusBefore } from '../src/before/desktop-app/src/renderer/features/home/chip/FanStatus';
import { FanStatus as FanStatusAfter } from '../src/after/desktop-app/src/renderer/features/home/chip/FanStatus';
import { Models as ModelsBefore } from '../src/before/desktop-app/src/renderer/features/models/Models';
import { Models as ModelsAfter } from '../src/after/desktop-app/src/renderer/features/models/Models';
import { StartServing as StartBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/StartServing';
import { StartServing as StartAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/StartServing';
import { HealthBar as HealthBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { HealthBar as HealthAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { OperationFeed as FeedBefore } from '../src/before/desktop-app/src/renderer/components/operations/OperationFeed';
import { OperationFeed as FeedAfter } from '../src/after/desktop-app/src/renderer/components/operations/OperationFeed';
import { RuntimeSetup as SetupBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { RuntimeSetup as SetupAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { LiveModels as LiveBefore } from '../src/before/desktop-app/src/renderer/features/insights/LiveModels';
import { LiveModels as LiveAfter } from '../src/after/desktop-app/src/renderer/features/insights/LiveModels';
import beforeComponentsCss from '../src/before/desktop-app/src/renderer/styles/components.css?raw';
import afterComponentsCss from '../src/after/desktop-app/src/renderer/styles/components.css?raw';
import type { BackendState } from '../src/after/desktop-app/src/renderer/useBackend';
import type {
  Action,
  CloudData,
  CoolingData,
  DesktopStatus,
  Operation,
  Snapshot,
} from '../src/after/desktop-app/src/shared/contracts';
import { Compare, Observed } from './support/Compare';
import { DockDialogs, shellFixtures } from './support/Shell';
import { resetBridges, succeeded, type Version } from './support/bridge';
import { backendFor, poolSnapshot, snapshot } from './support/fixtures';

const meta: Meta = { title: 'Third pass/Fixes', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const noop = () => {};
const now = () => Math.floor(Date.now() / 1000);
const later = <T,>(ms: number, value: T) =>
  new Promise<T>((resolve) => setTimeout(() => resolve(value), ms));
const panes = (canvasElement: HTMLElement) => [
  ...canvasElement.querySelectorAll<HTMLElement>('.sb-panes > .sb-pane'),
];
const pane = (canvasElement: HTMLElement, version: Version) =>
  canvasElement.querySelector<HTMLElement>(`.sb-panes > .sb-${version}`)!;

function Steps({ items, tone }: { items: string[]; tone: 'bad' | 'good' }) {
  return (
    <ol className={`sb-steps sb-steps-${tone}`}>
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ol>
  );
}

/** A small caption above one of several states rendered in a pane. */
const Caption = ({ children }: { children: ReactNode }) => (
  <h3 style={{ margin: '18px 0 8px', fontSize: 13, opacity: 0.8 }}>{children}</h3>
);

// ---------------------------------------------------------------------------------------------
// #1486: a CSS-only fix to how Electron routes clicks. Chrome (and so Storybook) ignores
// -webkit-app-region, so nothing here can show the window moving; the panes show each tree's
// actual .modal-backdrop rule, read from its stylesheet.

const backdropRule = (css: string) =>
  css.match(/\.modal-backdrop\s*\{[^}]*\}/)?.[0].replace(/\n\s*\n/g, '\n') ?? '(rule not found)';

export const DialogDragRegion: Story = {
  name: '#1486 Dialogs over the sidebar and top bar',
  render: () => (
    <Compare
      pr={1486}
      title="Dialogs, including sign-in, wouldn't close when clicking outside them over the sidebar or top bar"
      wrong={
        <>
          <p>
            The window is frameless, so the sidebar (<code>.sidebar</code>, the full left column)
            and the top bar (<code>.topbar</code>) declare <code>-webkit-app-region: drag</code>.
            Electron applies drag regions to mouse input even under elements stacked above them,
            unless the covering element opts out. The shared <code>Modal</code>'s full-window{' '}
            <code>.modal-backdrop</code> (which closes the dialog on click) didn't, so a click on
            the dimmed background over those areas moved the window and never reached it.
          </p>
          <p>
            A user reported the sign-in dialog “will not close out or cancel”: its account control
            sits at the bottom of the sidebar, and after <b>Cancel</b> the dialog stays open by
            design (“Sign-in cancelled.” with <b>Try again</b>). Every dialog shared the backdrop.
          </p>
        </>
      }
      fixed={
        <p>
          <code>.modal-backdrop</code> declares <code>-webkit-app-region: no-drag</code>, so the
          click reaches the backdrop and the dialog closes. A test checks that every full-window
          overlay (<code>position: fixed; inset: 0</code>) in the renderer's stylesheets opts
          out. Drag regions only exist in Electron; Chrome ignores the property, so this story
          can't demonstrate the click and shows each tree's rule instead.
        </p>
      }
      before={
        <>
          <Observed>
            <code>styles/components.css</code> at <code>bfa75a2c</code>:
          </Observed>
          <pre className="sb-observed" style={{ whiteSpace: 'pre-wrap' }}>
            {backdropRule(beforeComponentsCss)}
          </pre>
          <Steps
            tone="bad"
            items={[
              'Dialog open; click the dimmed background over the sidebar or top bar',
              'The backdrop declares no app region, so the drag region beneath takes the click',
              'The window moves (or nothing happens); the dialog stays open',
              'In a short window, dialog controls over the top bar strip didn’t respond either',
            ]}
          />
        </>
      }
      after={
        <>
          <Observed>
            <code>styles/components.css</code> on the integration build:
          </Observed>
          <pre className="sb-observed" style={{ whiteSpace: 'pre-wrap' }}>
            {backdropRule(afterComponentsCss)}
          </pre>
          <Steps
            tone="good"
            items={[
              'Same click',
              'The backdrop is no-drag, so the click reaches it',
              'onClick → onClose: the dialog closes',
            ]}
          />
        </>
      }
    />
  ),
};

// The drag regions, outlined, in the real app shell (Electron-only behavior can't run here).
const dragMap =
  '.sb-drag-map .sidebar, .sb-drag-map .topbar { outline: 2px dashed #f87171; outline-offset: -3px; }';

export const DialogDragRegionShell: Story = {
  name: '#1486 Drag regions in the full app',
  beforeEach: () => shellFixtures(),
  play: async ({ canvasElement }) => {
    const after = within(pane(canvasElement, 'after'));
    await userEvent.click(await after.findByRole('button', { name: 'Help' }, { timeout: 8000 }));
  },
  render: () => (
    <Compare
      pr={1486}
      title="Where the window's drag regions are when a dialog is open"
      wrong={
        <p>
          The real <code>App</code> from each tree, with its drag regions outlined in dashed red:
          the whole sidebar and the top bar declare <code>-webkit-app-region: drag</code>. A
          dialog's full-window backdrop sits over them. In the base the backdrop didn't opt out,
          so in Electron a click on the dimmed area over an outline moved the window instead of
          closing the dialog (the reported case was sign-in, opened from the bottom of the
          sidebar). The base has no Help dialog; every dialog shared the same backdrop.
        </p>
      }
      fixed={
        <p>
          The backdrop declares <code>-webkit-app-region: no-drag</code>, so those clicks reach it
          and close the dialog. The play step opens <b>Help</b> (#1503) in the After pane: its
          backdrop covers both outlined regions. Chrome ignores app regions, so this shows where
          the fix applies rather than the click itself (see the story above for each tree's
          rule).
        </p>
      }
      before={
        <div className="sb-drag-map">
          <style>{dragMap}</style>
          <AppBefore />
        </div>
      }
      after={
        <div className="sb-drag-map">
          <DockDialogs>
            <AppAfter />
          </DockDialogs>
        </div>
      }
      height={720}
      stack
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1487: Home's header button and the chip's screen-reader summary in transitional states.

/** The header button and what a screen reader gets from the chip, read from the rendered Home. */
function HomeReadout({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [text, setText] = useState({ button: '…', live: '…', summary: '…' });
  useEffect(() => {
    const read = () => {
      const root = ref.current;
      const button = root?.querySelector<HTMLButtonElement>('button');
      const stage = root?.querySelector('section[aria-label$="chip activity"]');
      const live = stage?.querySelector('[aria-live="polite"]')?.textContent ?? '';
      // Before #1478 the summary itself was the live region; after, it's a separate paragraph.
      const summary = stage?.querySelector(':scope > p:not([aria-live])')?.textContent ?? live;
      setText({
        button: button
          ? `${button.textContent?.trim()}${button.disabled ? ' (disabled)' : ''}`
          : '—',
        live: JSON.stringify(live),
        summary: JSON.stringify(summary),
      });
    };
    read();
    const timer = setInterval(read, 1000);
    return () => clearInterval(timer);
  }, []);
  return (
    <div ref={ref}>
      <div style={{ height: 64, overflow: 'hidden' }}>{children}</div>
      <Observed>
        Header button: <b>{text.button}</b>
        <br />
        Chip summary: <code>{text.summary}</code>
        <br />
        Announced: <code>{text.live}</code>
      </Observed>
    </div>
  );
}

const homeStates: { label: string; state: () => Snapshot }[] = [
  { label: 'state: "starting"', state: () => poolSnapshot({}, { state: 'starting' }) },
  { label: 'state: "running", activity not fresh', state: () => poolSnapshot() },
  { label: 'state: "draining"', state: () => poolSnapshot({}, { state: 'draining' }) },
  { label: 'state: "stale" (process up, status out of date)', state: () => poolSnapshot({}, { state: 'stale' }) },
];

export const HomeTransitionalStates: Story = {
  name: '#1487 Home while starting, draining or stale',
  play: async ({ canvasElement }) => {
    // Click every header button: Before opens Models (navigate, not logged) or stops; the log
    // shows which states could still send `stop`.
    for (const p of panes(canvasElement))
      for (const head of p.querySelectorAll<HTMLElement>('.sb-home-head')) {
        const button = head.querySelector<HTMLButtonElement>('button');
        if (button && !button.disabled) await userEvent.click(button);
      }
  },
  render: () => (
    <Compare
      pr={1487}
      title="Home offered “Start providing” while the provider was starting, draining or stale"
      wrong={
        <>
          <p>
            The header button showed <b>Stop provider</b> only when <code>state</code> was exactly{' '}
            <code>running</code>. Starting and draining (transitions to wait out) and stale (the
            provider process is still up, so it can be stopped) all got <b>Start providing</b>,
            which opens Models; a stale provider couldn't be stopped from Home.
          </p>
          <p>
            The chip counts running, draining and stale as powered, and its screen-reader summary
            always said “live activity”, even with no live numbers shown, ending in a stray
            space.
          </p>
        </>
      }
      fixed={
        <p>
          Starting reads <b>Starting…</b> and draining <b>Finishing requests</b>, both disabled;
          stale offers <b>Stop serving</b>. The summary says “live activity” only while the numbers
          are shown, otherwise why: “waiting for live activity”, “finishing current requests” or
          “status out of date”. (#1487 itself said <b>Starting provider</b> and <b>Stop
          provider</b>; #1501 later renamed them, so the After pane shows today's labels.) Each row
          is the real Home cut to its header; the readout is read from its DOM. The play step
          clicks every enabled header button; the log shows the <code>stop</code> actions sent.
        </p>
      }
      before={homeStates.map(({ label, state }) => (
        <div key={label} className="sb-home-head">
          <Caption>{label}</Caption>
          <HomeReadout>
            <HomeBefore backend={backendFor('before', state())} navigate={noop} openMachine={noop} />
          </HomeReadout>
        </div>
      ))}
      after={homeStates.map(({ label, state }) => (
        <div key={label} className="sb-home-head">
          <Caption>{label}</Caption>
          <HomeReadout>
            <HomeAfter backend={backendFor('after', state())} navigate={noop} openMachine={noop} />
          </HomeReadout>
        </div>
      ))}
      log
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1488: the overview's Fans cell with a five-minute-old reading.

const oldCooling = (): CoolingData => ({
  supported: true,
  enabled: true,
  mode: 'automatic',
  observed_at: now() - 300,
  temperature: 71.6,
  fans: [{ name: 'Fan', rpm: 4100, max_rpm: 5000 }],
});

export const OverviewStaleFans: Story = {
  name: '#1488 Overview fans with a five-minute-old reading',
  render: () => (
    <Compare
      pr={1488}
      title="This Mac's overview showed a five-minute-old fan reading as current"
      wrong={
        <p>
          My Macs › This Mac › Overview: the <b>Fans</b> cell ignored{' '}
          <code>cooling.observed_at</code>. With a reading 300 s old it still showed “Spinning ·
          4,100 RPM”, a turning fan glyph and “72°C GPU”, while Home's fan button (shown under the
          cell, same data) and the Cooling page already said “Fan status unavailable” after 60 s.
        </p>
      }
      fixed={
        <p>
          A shared <code>coolingStale()</code> (older than a minute) is used by the cell, Home's
          button and the Cooling status. A stale reading reads “Unavailable · The last fan reading
          is out of date.” with no RPM, glyph or GPU temperature. Fresh readings are unchanged.
        </p>
      }
      before={
        <div style={{ maxWidth: 380, display: 'grid', gap: 16 }}>
          <FanHealthBefore cooling={oldCooling()} />
          <FanStatusBefore cooling={oldCooling()} onOpen={noop} />
        </div>
      }
      after={
        <div style={{ maxWidth: 380, display: 'grid', gap: 16 }}>
          <FanHealthAfter cooling={oldCooling()} />
          <FanStatusAfter cooling={oldCooling()} onOpen={noop} />
        </div>
      }
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1489: model slots, not memory, block Keep in memory.

/** The disabled state and tooltip (title) of a control, read from the rendered page. */
function Tooltip({ label, children }: { label: string; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [text, setText] = useState('…');
  useEffect(() => {
    const read = () => {
      const button = ref.current?.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`);
      setText(
        button
          ? `${button.disabled ? 'disabled' : 'enabled'} · title: “${button.title || '(none)'}”`
          : 'not found',
      );
    };
    read();
    const timer = setInterval(read, 1000);
    return () => clearInterval(timer);
  }, [label]);
  return (
    <div ref={ref}>
      <Observed>
        <b>{label}</b>: {text}
      </Observed>
      {children}
    </div>
  );
}

// 16.4 + 21.4 + 7.2 = 45 GB of 64 GB fits, but only two models may stay loaded.
const slotsFull = () =>
  poolSnapshot(
    { pinned: ['gpt-oss-20b', 'gemma-4-26b'] },
    { memory: { total_gb: 64, active_gb: 37.8, free_for_load_gb: 20, max_model_slots: 2 } },
  );

export const SlotLimitReason: Story = {
  name: '#1489 Keep in memory blocked by model slots',
  render: () => (
    <Compare
      pr={1489}
      title="Keep in memory blamed memory when all model slots were in use"
      wrong={
        <p>
          With <code>max_model_slots: 2</code> and GPT-OSS 20B and Gemma 4 26B kept in memory,
          Qwen 3.5 9B's <b>Keep in memory</b> was disabled with “Pinning this needs more memory
          than this Mac has.” The three need 45 GB of 64 GB; the limit is the slot count.{' '}
          <code>pinnedMemory().exceeds</code> was true for either limit and the page always gave
          the memory reason.
        </p>
      }
      fixed={
        <p>
          <code>pinnedMemory()</code> also returns which <code>limit</code> is exceeded (memory
          wins when both are): “All 2 model slots are in use. Stop keeping another model in memory
          first.”, and for memory “Keeping this in memory needs more memory than this Mac has.”
          What can be kept is unchanged; only the reason differs. The tooltip is read from the
          button's <code>title</code>.
        </p>
      }
      before={
        <Tooltip label="Keep Qwen 3.5 9B in memory">
          <ModelsBefore backend={backendFor('before', slotsFull())} embedded />
        </Tooltip>
      }
      after={
        <Tooltip label="Keep Qwen 3.5 9B in memory">
          <ModelsAfter backend={backendFor('after', slotsFull())} embedded />
        </Tooltip>
      }
      stack
    />
  ),
};

const pinTwo = async (canvasElement: HTMLElement) => {
  for (const p of panes(canvasElement)) {
    const scope = within(p);
    await userEvent.click(scope.getByRole('button', { name: 'Advanced' }));
    // The checkbox itself is visually hidden; its label is what a user clicks.
    for (const name of [/GPT-OSS 20B/, /Qwen 3\.5 9B/])
      await userEvent.click(scope.getByRole('checkbox', { name }).closest('label')!);
  }
};
const oneSlot = () => snapshot({ memory: { total_gb: 64, max_model_slots: 1 } });

export const SlotLimitOnboarding: Story = {
  name: '#1489 Onboarding: more models than slots',
  play: async ({ canvasElement }) => pinTwo(canvasElement),
  render: () => (
    <Compare
      pr={1489}
      title="Onboarding said “more memory than this Mac has” for a slot limit"
      wrong={
        <p>
          On a 64 GB Mac whose runtime keeps one model loaded (<code>max_model_slots: 1</code>),
          choosing two models to keep in memory under <b>Advanced</b> read “That’s more memory
          than this Mac has; choose fewer models.” (The play step opens Advanced and picks GPT-OSS
          20B and Qwen 3.5 9B.)
        </p>
      }
      fixed={
        <p>
          The summary names the slot limit: “That’s more models than this Mac keeps in memory at
          once; choose fewer models.” Start stays disabled in both. (The “pinned” → “kept in
          memory” noun is the #1477 follow-up.)
        </p>
      }
      before={<StartBefore backend={backendFor('before', oneSlot())} snapshot={oneSlot()} done={noop} />}
      after={<StartAfter backend={backendFor('after', oneSlot())} snapshot={oneSlot()} link={noop} done={noop} />}
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1490: manual model actions while Autopilot turns on.

const manualMode = () => poolSnapshot({ enabled: false, phase: 'off' });

export const ApplyDuringAutopilot: Story = {
  name: '#1490 Apply selection while Autopilot turns on',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return manualMode();
        throw new Error('Unavailable in Storybook');
      },
      // The turn-on stays in flight for a minute, as a slow link check or drain would.
      act: (action: Action) =>
        later(action.action === 'autopilot' ? 60_000 : 500, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    for (const p of panes(canvasElement)) {
      const scope = within(p);
      const more = scope.queryByRole('button', { name: /Show \d+ more model/ });
      if (more) await userEvent.click(more);
      await userEvent.click(scope.getByRole('checkbox', { name: 'Select Qwen 3.5 9B' }));
      await userEvent.click(scope.getByRole('button', { name: 'Turn on Autopilot' }));
      await scope.findByRole('button', { name: 'Turning on…' });
      const apply = scope.getByRole('button', { name: /Apply selection/ });
      if (!(apply as HTMLButtonElement).disabled) await userEvent.click(apply);
    }
  },
  render: () => (
    <Compare
      pr={1490}
      title="Apply selection, Download and Remove stayed enabled while Autopilot turned on"
      wrong={
        <p>
          With Autopilot off, Models shows the manual selection under the turn-on offer. After{' '}
          <b>Turn on Autopilot</b> the button read “Turning on…”, but <b>Apply selection</b>,{' '}
          <b>Download</b> and <b>Remove</b> only checked <code>backend.busy</code>, which doesn't
          see the turn-on (a model action in <code>actions.working</code>) until the runtime
          reports an operation. A click sent <code>switch</code> on top of the turn-on.
        </p>
      }
      fixed={
        <p>
          <code>ManualModels</code> gets the same busy check <code>AutopilotModels</code> uses
          (<code>backend.busy</code> or any model action in flight), so the three controls are
          disabled until the turn-on ends. Selecting stays enabled. The play step selects Qwen 3.5
          9B, clicks <b>Turn on Autopilot</b> (held in flight), then <b>Apply selection</b> if
          enabled; compare the logs.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', manualMode())} embedded />}
      after={<ModelsAfter backend={backendFor('after', manualMode())} embedded />}
      log
      stack
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1491: This Mac's readiness while a required update runs.

const cloudFloor: CloudData = {
  linked: true,
  observed_at: now(),
  machines: [],
  minimum_provider_version: '0.9.10',
};
const latestRelease = { version: '0.9.16', published_at: '2026-10-12T00:00:00Z', notes: 'Fixture release' };
const updating = (): Snapshot =>
  poolSnapshot({}, {
    version: '0.9.2',
    operations: [
      { id: 'update-running', action: 'update', state: 'running', started_at: now() - 20, message: '', cancellable: false },
    ],
  });
const updatingBackend = (version: Version) =>
  backendFor(version, updating(), { cloud: cloudFloor, release: latestRelease, busy: true });

export const RequiredUpdateInProgress: Story = {
  name: '#1491 Required update while it runs',
  render: () => (
    <Compare
      pr={1491}
      title="This Mac offered the required update again while it was running"
      wrong={
        <p>
          Runtime 0.9.2 below the account's floor (0.9.10), latest release 0.9.16, and an{' '}
          <code>update</code> operation running. <code>assessReadiness</code> added the required
          update step whenever <code>update.required</code> was true, so the headline stayed
          <b> Update Darkbloom</b> (blocked) and Next steps listed “Updating Darkbloom · Wait for it
          to finish.” <i>and</i> “Update Darkbloom” with <b>Update now</b> (disabled only because
          the app is busy). Both panes get the release data; on the base My Macs didn't load it
          (#1454), so there the step had no button.
        </p>
      }
      fixed={
        <p>
          A running update is the remedy for a required one: the step is suppressed while it runs,
          so the headline is <b>Updating Darkbloom</b> (pending) with one step. If the update
          fails or is cancelled, no update is running and the required step returns.
        </p>
      }
      before={<HealthBefore backend={updatingBackend('before')} navigate={noop} />}
      after={<HealthAfter backend={updatingBackend('after')} navigate={noop} />}
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1492: download notifications. OperationToast portals to document.body and is fixed to the
// window; Docked moves each toast into its own pane surface (whose transform contains fixed
// elements). Toasts are inserted in tree order, so each Docked takes the first one still in body.

function Docked({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const host = ref.current!;
    const toast = document.body.querySelector<HTMLElement>(':scope > aside.operation');
    if (!toast) return;
    host.append(toast);
    return () => {
      if (toast.parentNode === host) document.body.append(toast);
    };
  }, []);
  return <div ref={ref}>{children}</div>;
}

const download = (state: Operation['state'], progress?: number): Snapshot =>
  poolSnapshot({}, {
    operations: [
      {
        id: `download-qwen-${state}`,
        action: 'download',
        state,
        model: 'qwen-3.5-9b',
        progress,
        started_at: now() - 40,
        finished_at: state === 'running' ? undefined : now(),
        message: state === 'failed' ? 'Not enough free disk space to download Qwen 3.5 9B.' : 'Downloading qwen-3.5-9b…',
        cancellable: state === 'running',
      },
    ],
  });
const toastCases: { label: string; state: () => Snapshot }[] = [
  { label: 'Running, progress: 0.42', state: () => download('running', 0.42) },
  { label: 'Running, no progress reported yet', state: () => download('running') },
  { label: 'Failed', state: () => download('failed') },
];
const Toasts = ({ version }: { version: Version }) => {
  const Feed = version === 'before' ? FeedBefore : FeedAfter;
  return (
    <>
      {toastCases.map(({ label, state }) => (
        <div key={label}>
          <Caption>{label}</Caption>
          <div style={{ position: 'relative', transform: 'translateZ(0)', height: 110, overflow: 'hidden' }}>
            <Docked>
              <Feed backend={backendFor(version, state()) as BackendState} />
            </Docked>
          </div>
        </div>
      ))}
    </>
  );
};

export const DownloadNotification: Story = {
  name: '#1492 Download notification',
  render: () => (
    <Compare
      pr={1492}
      title="The download notification didn't say which model or how far along"
      wrong={
        <p>
          The notification at the bottom used <code>operationLabel(action, state)</code> only:
          “Downloading model” while running and “Model download · Failed” afterwards, although the
          runtime reports the <code>model</code> and <code>progress</code> on the operation and
          the model's row on Models already shows them.
        </p>
      }
      fixed={
        <p>
          <code>operationTitle()</code> names the model with the catalog name (falling back to
          the id) and the row's rounded progress: “Downloading Qwen 3.5 9B · 42%”, “Downloading
          Qwen 3.5 9B”, “Qwen 3.5 9B download · Failed”. A download the runtime doesn't attribute
          still reads “Downloading model”. Same operation fixtures in both panes.
        </p>
      }
      before={<Toasts version="before" />}
      after={<Toasts version="after" />}
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// Follow-up commits on earlier PRs.

const statuses: { label: string; before: DesktopStatus; after: DesktopStatus }[] = [
  {
    label: 'Runtime missing (ENOENT)',
    before: { state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' },
    after: { state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' },
  },
  {
    label: 'Runtime failed to start',
    before: { state: 'error', message: 'Could not connect to the runtime. Update or repair the installation.' },
    after: { state: 'error', message: 'Could not connect to the Darkbloom CLI. Update or repair it.' },
  },
  {
    label: 'Runtime answered in another protocol',
    before: { state: 'error', message: 'Could not connect to the runtime. Update or repair the installation.' },
    after: {
      state: 'incompatible',
      message: 'The installed Darkbloom CLI is not compatible with this version of the app. Update the CLI.',
    },
  },
];

export const ReturningUserStartupWording: Story = {
  name: '#1456 follow-up: why a returning user can’t start',
  render: () => (
    <Compare
      pr={1456}
      title="Returning users were told “We couldn’t check this Mac” at startup"
      wrong={
        <>
          <p>
            #1456's <code>Startup</code> screen reused onboarding's <code>RuntimeSetup</code>, so
            a returning user whose runtime was missing read “Install Darkbloom to check this
            Mac.”, and one whose runtime failed read “We couldn’t check this Mac.”, although there
            is no check to run. The main process also reported a runtime that answered in another
            protocol as a plain <code>error</code>, described as one Darkbloom “couldn’t reach”
            with a repair offered.
          </p>
          <p>
            Before pane: the base's <code>RuntimeSetup</code>, the component #1456's first version
            showed returning users unchanged (on the base itself they got first-run Welcome; see{' '}
            <i>Fixes › Onboarding and launch</i>). Statuses as the base main process reported them.
          </p>
        </>
      }
      fixed={
        <p>
          Commit <code>6adb869fa</code>: a protocol mismatch is reported as the existing{' '}
          <code>incompatible</code> status, and <code>Startup</code> passes{' '}
          <code>returningUser</code>: “Reinstall Darkbloom to continue.” (missing), “Darkbloom
          couldn’t start.” (failed) and “Update Darkbloom to continue.” (incompatible). The
          action still runs the installer; only the label changes. The After pane is today's
          build, where #1502/#1504 later put this copy in CLI terms (“Reinstall the Darkbloom CLI
          to continue.” with <b>Install CLI</b>, <b>Repair CLI</b>, “Update the Darkbloom CLI to
          continue.” with <b>Update CLI</b>), with the main process's current messages.
        </p>
      }
      before={statuses.map(({ label, before }) => (
        <div key={label}>
          <Caption>{label}</Caption>
          <SetupBefore backend={backendFor('before', undefined, { status: before })} />
        </div>
      ))}
      after={statuses.map(({ label, after }) => (
        <div key={label}>
          <Caption>{label}</Caption>
          <SetupAfter backend={backendFor('after', undefined, { status: after })} returningUser />
        </div>
      ))}
    />
  ),
};

/** Live activity is judged against the clock, so the snapshot is re-stamped every 2 s. */
function Fresh({ children }: { children: (state: Snapshot) => ReactNode }) {
  const [at, setAt] = useState(now);
  useEffect(() => {
    const timer = setInterval(() => setAt(now()), 2000);
    return () => clearInterval(timer);
  }, []);
  const state = poolSnapshot({}, {
    observed_at: at,
    activity: {
      samples: [],
      sampled_at: at,
      models: [
        { model: 'gpt-oss-20b', state: 'running', running: 1, waiting: 0 },
        { model: 'gemma-4-26b', state: 'idle', running: 0, waiting: 0 },
      ],
    },
  });
  return <>{children(state)}</>;
}

export const OneRequestProcessing: Story = {
  name: '#1472 follow-up: one request processing',
  render: () => (
    <Compare
      pr={1472}
      title="Live activity said “1 requests processing”"
      wrong={
        <p>
          Stats › Models at work printed a fixed plural next to the live count, so a single
          in-flight request read “1 requests processing”. #1472 had fixed the other counts.
        </p>
      }
      fixed={
        <p>
          Commit <code>7d14f9c7a</code>: “1 request processing”; any other count, and the “—”
          shown when activity isn't current, keep “requests”. Fresh activity with one request
          running on GPT-OSS 20B in both panes.
        </p>
      }
      before={<Fresh>{(state) => <LiveBefore state={state} />}</Fresh>}
      after={<Fresh>{(state) => <LiveAfter state={state} />}</Fresh>}
    />
  ),
};

export const KeptInMemoryOnboarding: Story = {
  name: '#1477 follow-up: “kept in memory” in onboarding',
  play: async ({ canvasElement }) => pinTwo(canvasElement),
  render: () => (
    <Compare
      pr={1477}
      title="Onboarding still said “pinned”"
      wrong={
        <p>
          #1477 replaced “pins” with “Keep in memory” across the app, but onboarding's{' '}
          <b>Advanced</b> options still summarized the choice as “2 pinned · at least 22.5 GB of 64
          GB memory” (and Local only “runs just the models you pin”). The play step opens Advanced
          and picks GPT-OSS 20B and Qwen 3.5 9B.
        </p>
      }
      fixed={
        <p>
          Commit <code>821ef851d</code>: “2 kept in memory · at least 22.5 GB of 64 GB memory”, and
          “Local only runs just the models you keep in memory”. The lead above the list already
          said “kept in memory” after #1477. The After pane is today's build, where #1502 removed
          the local-only choice (“How this Mac is used”) from onboarding, so only the summary line
          is left to compare.
        </p>
      }
      before={<StartBefore backend={backendFor('before', snapshot())} snapshot={snapshot()} done={noop} />}
      after={<StartAfter backend={backendFor('after', snapshot())} snapshot={snapshot()} link={noop} done={noop} />}
    />
  ),
};

export const KeepingInMemoryLabel: Story = {
  name: '#1477 follow-up: “Keeping in memory…” on Models',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'state') return poolSnapshot();
        throw new Error('Unavailable in Storybook');
      },
      // Long enough to read the in-progress label.
      act: (action: Action) => later(60_000, succeeded(action.action)),
    }),
  play: async ({ canvasElement }) => {
    for (const version of ['before', 'after'] as const)
      await userEvent.click(
        within(pane(canvasElement, version)).getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' }),
      );
  },
  render: () => (
    <Compare
      pr={1477}
      title="Models labeled in-progress actions “Pinning…” and “Unpinning…”"
      wrong={
        <p>
          While <b>Keep in memory</b> ran, the model's row read “Pinning…” (and “Unpinning…” for
          Stop keeping), the last “pin” wording on the Models page. The play step clicks{' '}
          <b>Keep in memory</b> on Qwen 3.5 9B; the mocked runtime holds the action for a minute.
        </p>
      }
      fixed={
        <p>
          Commit <code>821ef851d</code>: “Keeping in memory…”, and “Updating…” while stopping.
          Same <code>autopilot_pin</code> action in both logs.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', poolSnapshot())} embedded />}
      after={<ModelsAfter backend={backendFor('after', poolSnapshot())} embedded />}
      log
      stack
    />
  ),
};
