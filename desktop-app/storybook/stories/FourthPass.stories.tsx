import { useLayoutEffect, useRef, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import AppBefore from '../src/before/desktop-app/src/renderer/App';
import AppAfter from '../src/after/desktop-app/src/renderer/App';
import { Home as HomeBefore } from '../src/before/desktop-app/src/renderer/features/Home';
import { Home as HomeAfter } from '../src/after/desktop-app/src/renderer/features/Home';
import { MachineHeader as MachineHeaderBefore } from '../src/before/desktop-app/src/renderer/features/machines/MachineHeader';
import { MachineHeader as MachineHeaderAfter } from '../src/after/desktop-app/src/renderer/features/machines/MachineHeader';
import { HealthBar as HealthBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { HealthBar as HealthAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import { Updates as UpdatesBefore } from '../src/before/desktop-app/src/renderer/features/Updates';
import { Updates as UpdatesAfter } from '../src/after/desktop-app/src/renderer/features/Updates';
import { Models as ModelsBefore } from '../src/before/desktop-app/src/renderer/features/models/Models';
import { Models as ModelsAfter } from '../src/after/desktop-app/src/renderer/features/models/Models';
import { Onboarding as OnboardingBefore } from '../src/before/desktop-app/src/renderer/components/Onboarding';
import { Onboarding as OnboardingAfter } from '../src/after/desktop-app/src/renderer/components/Onboarding';
import { StartServing as StartBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/StartServing';
import { StartServing as StartAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/StartServing';
import { RuntimeSetup as SetupBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { RuntimeSetup as SetupAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { ScanStep as ScanStepBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/ScanStep';
import { OperationFeed as FeedBefore } from '../src/before/desktop-app/src/renderer/components/operations/OperationFeed';
import { OperationFeed as FeedAfter } from '../src/after/desktop-app/src/renderer/components/operations/OperationFeed';
import { AccountSignInProgress as SignInBefore } from '../src/before/desktop-app/src/renderer/components/account/AccountSignInProgress';
import { AccountSignInProgress as SignInAfter } from '../src/after/desktop-app/src/renderer/components/account/AccountSignInProgress';
import { trayMenuModel as trayModelBefore } from '../src/before/desktop-app/src/main/trayMenu';
import { trayMenuModel as trayModelAfter, trayMenuTemplate } from '../src/after/desktop-app/src/main/trayMenu';
import { externalLinks } from '../src/after/desktop-app/src/shared/externalLinks';
import beforeTraySource from '../src/before/desktop-app/src/main/tray.ts?raw';
import beforePreviewSource from '../src/before/desktop-app/src/renderer/preview.ts?raw';
import afterPreviewSource from '../src/after/desktop-app/src/renderer/preview.ts?raw';
import type { BackendState } from '../src/after/desktop-app/src/renderer/useBackend';
import type {
  DesktopStatus,
  Machine,
  NetworkData,
  Operation,
  Snapshot,
} from '../src/after/desktop-app/src/shared/contracts';
import { Compare, Observed } from './support/Compare';
import { AtRoute, DockDialogs, shellFixtures } from './support/Shell';
import { resetBridges, type Version } from './support/bridge';
import { backendFor, poolSnapshot, snapshot } from './support/fixtures';

const meta: Meta = { title: 'Fourth pass/Team review fixes', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const noop = () => {};
const now = () => Math.floor(Date.now() / 1000);
const pane = (canvasElement: HTMLElement, version: Version) =>
  within(canvasElement.querySelector<HTMLElement>(`.sb-panes > .sb-${version}`)!);
/** One captioned row of a pane, found by its caption. */
const row = (canvasElement: HTMLElement, version: Version, caption: string) =>
  within(
    canvasElement.querySelector<HTMLElement>(`.sb-panes > .sb-${version} [data-row="${caption}"]`)!,
  );

function Steps({ items, tone }: { items: string[]; tone: 'bad' | 'good' }) {
  return (
    <ol className={`sb-steps sb-steps-${tone}`}>
      {items.map((item) => (
        <li key={item}>{item}</li>
      ))}
    </ol>
  );
}

/** A captioned state inside a pane; `data-row` lets the play step find it. */
const Row = ({ caption, children, short }: { caption: string; children: ReactNode; short?: boolean }) => (
  <div data-row={caption}>
    <h3 style={{ margin: '18px 0 8px', fontSize: 13, opacity: 0.8 }}>{caption}</h3>
    <div className={short ? 'sb-short' : undefined}>{children}</div>
  </div>
);

const pendingLink = (): NonNullable<Snapshot['link']> => ({
  url: 'https://example.invalid/link',
  code: 'BLOOM-7Q4K',
  expires_at: now() + 900,
  state: 'pending',
});
const runningLink: Operation = {
  id: 'link-1',
  action: 'link',
  state: 'running',
  started_at: now(),
  message: 'Waiting for approval',
  cancellable: true,
};

// ---------------------------------------------------------------------------------------------
// #1498: a native (Swift) change. Nothing in the renderer differs, so the panes explain.

export const NativeLinkNoAutoBrowser: Story = {
  name: '#1498 The link page opens only on click (native)',
  render: () => (
    <Compare
      pr={1498}
      title="Linking this Mac popped the browser open before the code was on screen"
      wrong={
        <p>
          The runtime's desktop <code>link</code> action (<code>DesktopBackend.swift</code>) called{' '}
          <code>performDeviceCodeLogin</code> with its default{' '}
          <code>automaticallyOpenBrowser: true</code>, so the system browser opened the link page
          as soon as the coordinator issued a code, while the app was still showing “Getting a
          link code…”. That happened from onboarding, Models (Autopilot) and Home alike. Desktop
          sign-in already waited for a click.
        </p>
      }
      fixed={
        <p>
          The desktop action passes <code>automaticallyOpenBrowser: false</code>: the app shows the
          code first and opens the link page only when the user clicks <b>Open link page</b>{' '}
          (the renderer's <code>openExternal('link')</code>). The CLI's own <code>darkbloom
          login</code> is unchanged. This is a Swift change, so Storybook can't run it: both panes
          render nothing of their own. The renderer side (no <code>openExternal</code> before the
          click) is exercised in <i>Flows › Onboarding › Step 2: Link your account</i>, whose log
          shows a single <code>openExternal link</code>, after the click.
        </p>
      }
      before={
        <Steps
          tone="bad"
          items={[
            'Click Link account (or Link this Mac & turn on Autopilot)',
            'The app sends {"action":"link"}',
            'The runtime asks the coordinator for a device code and opens the browser on it at once',
            'The link page appears in front of the app, before the code is readable there',
          ]}
        />
      }
      after={
        <>
          <Steps
            tone="good"
            items={[
              'Same click; the app sends {"action":"link"}',
              'The runtime reports the code in snapshot.link without opening anything',
              'The app shows the code, Open link page and Cancel',
              'The browser opens only when the user clicks Open link page',
            ]}
          />
          <Observed>
            <code>provider-swift/…/Desktop/DesktopBackend.swift</code>:{' '}
            <code>automaticallyOpenBrowser: false</code> on the desktop link request.
          </Observed>
        </>
      }
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1499: what an unlinked Mac's Autopilot buttons say, and the link dialog.

const machine = { ...poolSnapshot().machine, status: 'running', models: ['gpt-oss-20b', 'gemma-4-26b'] };
const off = (overrides: Partial<Snapshot> = {}) =>
  poolSnapshot({ enabled: false, phase: 'off' }, { machine, ...overrides });
const neverSetUp = (overrides: Partial<Snapshot> = {}) =>
  poolSnapshot(
    { configured: false, enabled: false, selected: [], pinned: [], phase: 'off' },
    {
      state: 'stopped',
      models: poolSnapshot().models.map((model) => ({ ...model, loaded: false, serving: false })),
      machine: { ...machine, status: 'stopped', models: [] },
      ...overrides,
    },
  );
const network = (): NetworkData => ({
  model_earnings: {
    window: '7d',
    as_of: new Date().toISOString(),
    models: [
      { id: 'qwen-3.6-35b', earnings_micro_usd: '48210000' },
      { id: 'gemma-4-26b', earnings_micro_usd: '31800000' },
      { id: 'gpt-oss-20b', earnings_micro_usd: '22050000' },
    ],
  },
});

export const AutopilotLinkLabels: Story = {
  name: '#1499 Unlinked Autopilot buttons say they link first',
  render: () => (
    <Compare
      pr={1499}
      title="Turning Autopilot on from an unlinked Mac didn't say it would link first"
      wrong={
        <p>
          On a Mac that isn't linked, every Autopilot start on Models runs the runtime's{' '}
          <code>link</code> action first. Nothing said so: the buttons read <b>Download &amp; start
          Autopilot</b> and <b>Turn on Autopilot</b>, and nothing mentioned a code, a browser page,
          or that Autopilot starts only after approval.
        </p>
      }
      fixed={
        <p>
          Unlinked, the buttons read <b>Link this Mac &amp; start Autopilot</b> (recommendations)
          and <b>Link this Mac &amp; turn on Autopilot</b> (toolbar, manual page offer), with an
          explanation before the click: you get a code here, open the link page in the browser to
          approve it, then Autopilot starts and downloads begin. Linked Macs keep the old labels.
          (The PR calls it a one-line explanation; it is three short sentences.)
        </p>
      }
      before={
        <>
          <Row caption="Never set up (Autopilot page), with recommendations">
            <ModelsBefore backend={backendFor('before', neverSetUp({ linked: false }), { network: network() })} embedded />
          </Row>
          <Row caption="Autopilot off (manual page)">
            <ModelsBefore backend={backendFor('before', off({ linked: false }))} embedded />
          </Row>
        </>
      }
      after={
        <>
          <Row caption="Never set up (Autopilot page), with recommendations">
            <ModelsAfter backend={backendFor('after', neverSetUp({ linked: false }), { network: network() })} embedded />
          </Row>
          <Row caption="Autopilot off (manual page)">
            <ModelsAfter backend={backendFor('after', off({ linked: false }))} embedded />
          </Row>
        </>
      }
      stack
    />
  ),
};

const linking = (state: Snapshot) => ({ ...state, linked: false, link: pendingLink(), operations: [runningLink] });

export const LinkDialogPanel: Story = {
  name: '#1499 Link dialog: Open link page and a real Cancel',
  play: async ({ canvasElement }) => {
    for (const version of ['before', 'after'] as const) {
      const dialog = within(pane(canvasElement, version).getByRole('dialog', { name: 'Link this Mac' }));
      await userEvent.click(dialog.getByRole('button', { name: 'Cancel' }));
    }
  },
  render: () => (
    <Compare
      pr={1499}
      title="The link dialog said “Open browser” and hid Cancel in a small text link"
      wrong={
        <p>
          Models' <i>Link this Mac</i> dialog (and onboarding's link panel, the same{' '}
          <code>LinkPanel</code>) said “Serving starts as soon as you approve this Mac in your
          browser.” with an <b>Open browser</b> button, and <b>Cancel</b> was a small text link in
          the footer. Both panes: the Autopilot page while a link code is pending (
          <code>snapshot.link</code> set, a running cancellable <code>link</code> operation).
        </p>
      }
      fixed={
        <p>
          The panel says where the code goes (“Open the link page and enter this code. Then
          approve this Mac.” in today's build, after #1502's wording), the button reads{' '}
          <b>Open link page</b>, and <b>Cancel</b> is a standard secondary button. Cancel still
          sends <code>cancel</code> for the running <code>link</code> operation: the play step
          clicks it in both panes; compare the logs.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', linking(poolSnapshot()))} embedded />}
      after={<ModelsAfter backend={backendFor('after', linking(poolSnapshot()))} embedded />}
      height={560}
      log
    />
  ),
};

export const LinkDialogManualPage: Story = {
  name: '#1499 Link code on the manual Models page',
  render: () => (
    <Compare
      pr={1499}
      title="Linking from the manual Models page showed no code at all"
      wrong={
        <p>
          With Autopilot configured but off, Models is the manual page with a{' '}
          <b>Turn on Autopilot</b> offer. On an unlinked Mac that offer starts a link, but only the
          Autopilot page rendered the <i>Link this Mac</i> dialog, so the runtime issued a code
          that the app never showed. Both panes: the manual page while a code is pending.
        </p>
      }
      fixed={
        <p>
          The dialog moved to <code>LinkDialog</code>, rendered by the manual page too: the code,{' '}
          <b>Open link page</b> and <b>Cancel</b>.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', linking(off()))} embedded />}
      after={<ModelsAfter backend={backendFor('after', linking(off()))} embedded />}
      height={560}
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1500: a dev-preview-only change. The signed app opens links in the main process.

const openExternalOf = (source: string) =>
  source.match(/(\/\/[^\n]*\n\s*)?async openExternal\([^)]*\)\s*\{[^}]*\}/)?.[0].replace(/^\s+/gm, (m) => m.slice(0, 2)) ??
  '(not found)';

export const PreviewExternalLinks: Story = {
  name: '#1500 External links in the browser preview',
  render: () => (
    <Compare
      pr={1500}
      title="In the browser dev preview, Read the guide, Terms and the other external links did nothing"
      wrong={
        <p>
          The browser development preview (<code>npm run dev</code>, <code>?preview</code>) has no
          Electron main process, so <code>previewAPI.openExternal</code> was an empty function:{' '}
          <i>Read the guide</i>, <i>Terms of Service</i>, <i>Privacy</i>, <i>Account &amp;
          payouts</i>, <i>Troubleshooting guide</i> and <i>Open browser</i> silently did nothing
          there. The signed app was never affected: its main process opens each target after
          checking it (<code>security.ts</code>).
        </p>
      }
      fixed={
        <p>
          The destinations moved to <code>src/shared/externalLinks.ts</code>, shared by the main
          process (whose https and host checks are unchanged) and the preview, which now opens the
          same URL in a new tab (<code>link</code> uses the preview's own link page URL). Storybook
          mocks the bridge, so it can't show a tab opening; the panes show each tree's{' '}
          <code>openExternal</code> in <code>preview.ts</code>, and the shared map.
        </p>
      }
      before={
        <>
          <Observed>
            <code>renderer/preview.ts</code> at <code>bfa75a2c</code>:
          </Observed>
          <pre className="sb-observed" style={{ whiteSpace: 'pre-wrap' }}>
            {openExternalOf(beforePreviewSource)}
          </pre>
        </>
      }
      after={
        <>
          <Observed>
            <code>renderer/preview.ts</code> on the integration build:
          </Observed>
          <pre className="sb-observed" style={{ whiteSpace: 'pre-wrap' }}>
            {openExternalOf(afterPreviewSource)}
          </pre>
          <Observed>
            <code>shared/externalLinks.ts</code> (also the main process's allowlisted targets):
          </Observed>
          <table className="sb-observed" style={{ borderCollapse: 'collapse', fontSize: 12 }}>
            <tbody>
              {Object.entries(externalLinks).map(([target, url]) => (
                <tr key={target}>
                  <td style={{ padding: '2px 12px 2px 0' }}>
                    <code>{target}</code>
                  </td>
                  <td>
                    <code>{url}</code>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      }
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1501: one verb, "serving", for starting and stopping this Mac.

const stopped = () =>
  poolSnapshot({}, {
    state: 'stopped',
    models: poolSnapshot().models.map((model) => ({ ...model, loaded: false })),
    memory: { total_gb: 64 },
  });
const header = (node: ReactNode) => <div style={{ height: 64, overflow: 'hidden' }}>{node}</div>;
const thisMac = (state: Snapshot): Machine => ({ ...machine, status: state.state });

const wordingRows = (version: Version) => {
  const Home = version === 'before' ? HomeBefore : HomeAfter;
  const Header = version === 'before' ? MachineHeaderBefore : MachineHeaderAfter;
  const Health = version === 'before' ? HealthBefore : HealthAfter;
  const b = (state: Snapshot) => backendFor(version, state) as BackendState;
  return (
    <>
      <Row caption="Home header, stopped">
        {header(<Home backend={b(stopped())} navigate={noop} openMachine={noop} />)}
      </Row>
      <Row caption="Home header, serving">
        {header(<Home backend={b(poolSnapshot())} navigate={noop} openMachine={noop} />)}
      </Row>
      <Row caption="This Mac header, stopped">
        <Header machine={thisMac(stopped())} local backend={b(stopped())} navigate={noop} />
      </Row>
      <Row caption="This Mac header, serving (hover Restart for its title)">
        <Header machine={thisMac(poolSnapshot())} local backend={b(poolSnapshot())} navigate={noop} />
      </Row>
      <Row caption="This Mac, Next steps while stopped">
        <Health backend={b(stopped())} navigate={noop} />
      </Row>
    </>
  );
};

export const ServingWordingScreens: Story = {
  name: '#1501 “Start serving” on Home and This Mac',
  render: () => (
    <Compare
      pr={1501}
      title="The app mixed “Start providing”, “Stop provider”, “Start provider” and “contributing”"
      wrong={
        <p>
          The same act had several names: Home offered <b>Start providing</b> /{' '}
          <b>Stop provider</b>, This Mac's header <b>Start provider</b> / <b>Stop provider</b>{' '}
          (and an icon button labeled just “Restart”), Next steps “Start providing” and “Restart
          the provider”, the menu bar <b>Start provider</b> and the raw runtime state, Updates
          “Keep contributing” and “Restart provider”.
        </p>
      }
      fixed={
        <p>
          One verb everywhere: <b>Start serving</b>, <b>Stop serving</b>, <b>Restart serving</b>{' '}
          (Home, This Mac, Next steps, operation names, the menu bar, Updates, Settings,
          Cooling). “Provider” remains only as the noun for people (Leaderboard's “Top
          providers”). Same fixtures in both panes; each Home is cut to its header. The Home
          rows also carry #1487 (Home's transitional states), which isn't in the base.
        </p>
      }
      before={wordingRows('before')}
      after={wordingRows('after')}
    />
  ),
};

/** Labels of the base tray menu, read from tray.ts (it builds an Electron Menu, which can't run here). */
const beforeTrayLabels = (status: string) =>
  [...beforeTraySource.matchAll(/label: (?:'([^']+)'|`([^`]+)`)/g)].map(([, plain, template]) =>
    plain ?? template.replace('${model.status}', status),
  );

function TrayMenu({ items }: { items: { label: string; enabled?: boolean }[] }) {
  return (
    <ul className="sb-observed" style={{ listStyle: 'none', margin: 0, maxWidth: 280 }}>
      {items.map((item, i) => (
        <li key={i} style={{ opacity: item.enabled === false ? 0.5 : 1, padding: '2px 0' }}>
          {item.label}
        </li>
      ))}
    </ul>
  );
}

const trayState = () => poolSnapshot();
const afterTray = () =>
  trayMenuTemplate(trayModelAfter(trayState()), {
    show: noop,
    start: noop,
    stop: noop,
    restart: noop,
    quit: noop,
  }).map((item) => ({ label: item.type === 'separator' ? '———' : String(item.label), enabled: item.enabled }));

export const ServingWordingUpdates: Story = {
  name: '#1501 Updates and the menu bar',
  play: async ({ canvasElement }) => {
    // Change the update preference so Updates asks for a restart.
    for (const version of ['before', 'after'] as const)
      await userEvent.click(pane(canvasElement, version).getByRole('switch', { name: 'Automatic provider updates' }));
  },
  render: () => (
    <Compare
      pr={1501}
      title="Updates said “Keep contributing” and “Restart provider”; the menu bar showed the raw state"
      wrong={
        <p>
          Updates: “Stay current. Keep contributing.”, “Preference changes apply on the next
          provider restart.”, and after a change “Saved. Restart the provider to apply.” with{' '}
          <b>Restart provider</b>. The menu bar: <b>Start provider</b>, <b>Stop provider</b>,{' '}
          <b>Restart provider</b>, and a title echoing the protocol state (“Darkbloom —
          running”).
        </p>
      }
      fixed={
        <p>
          “Stay current. Keep serving.”, “Preference changes apply the next time serving
          restarts.”, “Saved. Restart serving to apply.” with <b>Restart serving</b>. The menu
          bar says <b>Start serving</b> / <b>Stop serving</b> / <b>Restart serving</b> and names
          the state (Serving, Stopped, Starting…, Finishing requests, Connecting…). The play step
          toggles automatic updates in both panes so the restart prompt appears. The switch is
          still named “Automatic provider updates” in both. Menu bar: the After list is the real{' '}
          <code>trayMenuTemplate()</code> for a serving Mac; the base built its menu inline in{' '}
          <code>tray.ts</code> (Electron only), so its labels are read from that file.
        </p>
      }
      before={
        <>
          <UpdatesBefore backend={backendFor('before', poolSnapshot())} />
          <Row caption="Menu bar menu, serving (tray.ts labels)">
            <TrayMenu items={beforeTrayLabels(trayModelBefore(trayState()).status).map((label) => ({ label }))} />
          </Row>
        </>
      }
      after={
        <>
          <UpdatesAfter backend={backendFor('after', poolSnapshot())} />
          <Row caption="Menu bar menu, serving (trayMenuTemplate)">
            <TrayMenu items={afterTray()} />
          </Row>
        </>
      }
    />
  ),
};

export const ServingWordingShell: Story = {
  name: '#1501 This Mac in the full app',
  beforeEach: () => shellFixtures(),
  render: () => (
    <Compare
      pr={1501}
      title="This Mac, as it looks in the app, before and after the serving wording"
      wrong={
        <p>
          The real <code>App</code> from each tree on its development-preview fixtures, opened at
          My Macs › This Mac (through the bridge's <code>onNavigate</code>, as the menu bar does).
          The header offers <b>Stop provider</b> and an icon button labeled just “Restart”.
        </p>
      }
      fixed={
        <p>
          The same page reads <b>Stop serving</b>, and the icon button is labeled and titled{' '}
          <b>Restart serving</b>. The sidebar, top bar and the rest of the page are the real
          shell; the After sidebar also has <b>Help</b> (#1503). Scroll inside a pane for the
          rest of the page.
        </p>
      }
      before={
        <AtRoute version="before" route="machines">
          <AppBefore />
        </AtRoute>
      }
      after={
        <AtRoute version="after" route="machines">
          <AppAfter />
        </AtRoute>
      }
      height={760}
      stack
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1502: onboarding order (install, link, check, start) and a way out on every step.

const unlinkedFresh = () => snapshot({ linked: false });

export const OnboardingFirstScreen: Story = {
  name: '#1502 Onboarding: the first screen',
  render: () => (
    <Compare
      pr={1502}
      title="Onboarding linked last, and offered no way out until its last step"
      wrong={
        <>
          <p>
            Two steps, <b>1 Check this Mac → 2 Start</b>. Linking happened inline from the start
            button, after the check. <b>Explore the app first</b> was only on the Start step (plus{' '}
            <b>Open dashboard</b> on an ineligible or unconfirmed check), so a reviewer who opened
            onboarding by accident had to go through it. With no CLI installed, Welcome still
            came first and the install screen appeared only after <b>Start</b>.
          </p>
        </>
      }
      fixed={
        <p>
          Four steps: <b>1 Install CLI → 2 Check this Mac → 3 Link your account → 4 Start</b>.
          Step 1, “Install the Darkbloom CLI” (follow-up <code>04214bd10</code>, CLI wording
          since), stands in for every other step until the CLI is installed and connected, and
          nothing installs until <b>Install CLI</b> is clicked. Linking is its own step after the
          check, with a code, <b>Open link page</b> (the only thing that opens the browser) and{' '}
          <b>Cancel</b>; an ineligible Mac stops at the check and is never asked to link, and a
          linked Mac skips linking. <b>Explore the app first</b> sits beside the step list on
          every step once a snapshot exists. Both panes render the real <code>Onboarding</code>.
        </p>
      }
      before={
        <>
          <Row caption="CLI not installed (status missing)" short>
            <OnboardingBefore
              backend={backendFor('before', undefined, {
                status: { state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' },
              })}
              done={noop}
            />
          </Row>
          <Row caption="CLI connected, account not linked" short>
            <OnboardingBefore backend={backendFor('before', unlinkedFresh())} done={noop} />
          </Row>
        </>
      }
      after={
        <>
          <Row caption="CLI not installed (status missing)" short>
            <OnboardingAfter
              backend={backendFor('after', undefined, { status: missingIn('after') })}
              done={noop}
            />
          </Row>
          <Row caption="CLI connected, account not linked" short>
            <OnboardingAfter backend={backendFor('after', unlinkedFresh())} done={noop} />
          </Row>
        </>
      }
      stack
    />
  ),
};

export const OnboardingAdvanced: Story = {
  name: '#1502 Advanced without “How this Mac is used”',
  play: async ({ canvasElement }) => {
    for (const version of ['before', 'after'] as const)
      await userEvent.click(pane(canvasElement, version).getByRole('button', { name: 'Advanced' }));
  },
  render: () => (
    <Compare
      pr={1502}
      title="Onboarding's Advanced options offered “Use models locally”"
      wrong={
        <p>
          Under <b>Advanced</b>, the start step asked <i>How this Mac is used</i>:{' '}
          <b>Contribute to Darkbloom</b> or <b>Use models locally</b>, the latter turning
          onboarding into a local-only setup with its own copy (“Start local models”, “Local only
          doesn't need a Darkbloom account”). The product owner asked for onboarding to always set
          up serving. The play step opens Advanced in both panes.
        </p>
      }
      fixed={
        <p>
          Advanced holds only “Keep a model always on”. <code>ModeChoice.tsx</code> and the
          onboarding-only <code>local</code> start method are deleted; local models stay available
          in the app (Studio, Models, <code>darkbloom start --local</code>).
        </p>
      }
      before={<StartBefore backend={backendFor('before', snapshot())} snapshot={snapshot()} done={noop} />}
      after={<StartAfter backend={backendFor('after', snapshot())} snapshot={snapshot()} link={noop} done={noop} />}
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1503: Help in the sidebar, and a next step on failures.

export const SidebarHelp: Story = {
  name: '#1503 Help in the sidebar',
  beforeEach: () => shellFixtures(),
  play: async ({ canvasElement }) => {
    await userEvent.click(await pane(canvasElement, 'after').findByRole('button', { name: 'Help' }, { timeout: 8000 }));
  },
  render: () => (
    <Compare
      pr={1503}
      title="There was no visible help or support in the app"
      wrong={
        <p>
          <i>Read the guide</i> appeared only in onboarding's footer, and the troubleshooting guide
          was a link inside Stats' details. The sidebar had the community icons and the account
          control, nothing named Help.
        </p>
      }
      fixed={
        <p>
          <b>Help</b> above the community icons opens a dialog: <i>Read the guide</i>,{' '}
          <i>Ask in Slack</i>, <i>Community discussions</i>, and the version to mention when
          asking (“When you ask, mention Darkbloom 0.9.x.”). At the narrow sidebar width only the
          icon shows. Both panes are the real <code>App</code> on the development-preview
          fixtures; the play step opens Help in the After pane (the dialog is moved into that
          pane).
        </p>
      }
      before={<AppBefore />}
      after={
        <DockDialogs>
          <AppAfter />
        </DockDialogs>
      }
      height={720}
      stack
      log
    />
  ),
};

// OperationToast portals to document.body and is fixed to the window; move it into its row (whose
// transform contains fixed elements). It goes back to body before React unmounts it; Close only
// hides it here.
function Docked({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const host = ref.current!;
    const toast = document.body.querySelector<HTMLElement>(':scope > aside.operation');
    if (!toast) return;
    host.append(toast);
    const close = (event: Event) => {
      if ((event.target as Element).closest('[aria-label="Close notification"]')) {
        event.stopPropagation();
        toast.style.display = 'none';
      }
    };
    host.addEventListener('click', close);
    return () => {
      host.removeEventListener('click', close);
      if (toast.parentNode === host) document.body.append(toast);
    };
  }, []);
  return (
    <div style={{ position: 'relative', transform: 'translateZ(0)', height: 130, overflow: 'hidden' }}>
      <div ref={ref}>{children}</div>
    </div>
  );
}

const failedUpdate = (): Snapshot =>
  poolSnapshot({}, {
    operations: [
      {
        id: 'update-failed',
        action: 'update',
        state: 'failed',
        started_at: now() - 60,
        finished_at: now(),
        message: 'Could not download Darkbloom 0.9.21: the connection was reset.',
        cancellable: false,
      },
    ],
  });
const ipcInstallError = "Error invoking remote method 'backend:install': Error: Runtime installation failed";
const missing: DesktopStatus = { state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' };
// The same status as each version's main process words it.
const missingIn = (version: Version): DesktopStatus =>
  version === 'before' ? missing : { state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' };

const failureRows = (version: Version) => {
  const Feed = version === 'before' ? FeedBefore : FeedAfter;
  const Setup = version === 'before' ? SetupBefore : SetupAfter;
  const SignIn = version === 'before' ? SignInBefore : SignInAfter;
  return (
    <>
      <Row caption="A failed operation">
        <Docked>
          <Feed backend={backendFor(version, failedUpdate()) as BackendState} />
        </Docked>
      </Row>
      <Row caption="Installing the CLI failed (after a click)">
        <div className="onboarding-step">
          <Setup backend={backendFor(version, undefined, { status: missingIn(version) })} />
        </div>
      </Row>
      <Row caption="Sign-in didn't finish">
        <div style={{ maxWidth: 420 }}>
          <SignIn
            backend={backendFor(version, poolSnapshot(), { error: 'The sign-in code expired.' }) as BackendState}
            requestFailed
            submitting={false}
            onRetry={noop}
            onClose={noop}
          />
        </div>
      </Row>
    </>
  );
};

export const GetHelpOnFailures: Story = {
  name: '#1503 Get help on failures',
  beforeEach: () =>
    resetBridges({
      install: async () => {
        throw new Error(ipcInstallError);
      },
    }),
  play: async ({ canvasElement }) => {
    for (const version of ['before', 'after'] as const) {
      const install = row(canvasElement, version, 'Installing the CLI failed (after a click)');
      await userEvent.click(install.getByRole('button', { name: /Install/ }));
      await install.findByText(/Runtime installation failed/);
    }
  },
  render: () => (
    <Compare
      pr={1503}
      title="Failures said what went wrong, but not what to do next"
      wrong={
        <p>
          A failed or interrupted operation's notification had its title, details and Close; a
          failed CLI install showed the error over the same install button; a failed sign-in
          offered only <b>Try again</b>. None pointed anywhere for help.
        </p>
      }
      fixed={
        <p>
          Each adds <b>Get help</b>, which opens the guide (<code>docs</code>, the existing
          allowlisted target; there is no separate troubleshooting URL). Retry stays where the
          app can retry. Also (not shown): the not-connected notice above every page gets Get help
          when the backend can't be reached (<code>error</code>, <code>missing</code>,{' '}
          <code>incompatible</code>), but not while connecting or installing. The play step
          clicks the install button in both panes; the mocked installer rejects as Electron
          reports it.
        </p>
      }
      before={failureRows('before')}
      after={failureRows('after')}
      log
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1504: installing the CLI (which owns the backend): progress, Cancel, failure with Retry.

const waitingScan = {
  result: undefined,
  frame: { revealed: 0, resolved: 0, phase: 'waiting' as const },
  finish: noop,
  settled: false,
  blocked: false,
  recheck: async () => {},
};
const installingBefore: DesktopStatus = { state: 'installing', message: 'Installing the verified Swift runtime…' };
const baseFailure: DesktopStatus = { state: 'error', message: 'Installation failed. Check your connection and retry.' };

export const CliInstall: Story = {
  name: '#1504 Installing the CLI: progress, Cancel, Retry',
  beforeEach: () =>
    resetBridges({
      install: async () => {
        throw new Error(ipcInstallError);
      },
    }),
  play: async ({ canvasElement }) => {
    const failed = row(canvasElement, 'before', 'Install fails');
    await userEvent.click(failed.getByRole('button', { name: /Repair runtime/ }));
    await failed.findByText(/Runtime installation failed/);
    await userEvent.click(
      row(canvasElement, 'after', 'While the installer runs').getByRole('button', { name: /Cancel/ }),
    );
  },
  render: () => (
    <Compare
      pr={1504}
      title="Installing showed one line for minutes, and a failure's reason vanished"
      wrong={
        <>
          <p>
            With the CLI (<code>~/.darkbloom/bin/darkbloom</code>) missing, base onboarding opened
            on Welcome and showed the install screen only after <b>Start</b>. While installing,
            the check step said “Installing Darkbloom…” with “Installing the verified Swift
            runtime…” for minutes (the installer's output was buffered), and the watch loop
            switched the status back to <code>missing</code> every 5 s. A failure said
            “Installation failed. Check your connection and retry.”, which the{' '}
            <code>missing</code> text replaced within 5 s, and two installers could run at once.
          </p>
          <p>
            Before pane: the base <code>RuntimeSetup</code>; for the installing row, the base
            check step, which is what onboarding showed then. The play step clicks{' '}
            <b>Repair runtime</b> in the failure row (the mocked installer rejects as Electron
            reports it).
          </p>
        </>
      }
      fixed={
        <>
          <p>
            Install is onboarding's first screen (#1502) and starts when the user clicks it.
            Progress streams from the installer as plain steps (finding the release, downloading
            with a percentage, verifying the signature, setting up this Mac’s identity, finishing
            up), with <b>Cancel</b> (<code>api.cancelInstall()</code>, clicked by the play step)
            and no second install button; button and window share one installer. A failure keeps
            the step and the installer's own reason on screen with <b>Retry</b> and{' '}
            <b>Get help</b> (#1503).
          </p>
          <p>
            The app installs the <b>Darkbloom CLI</b>, which owns the background service and its
            updates. #1504 first added an automatic install on first launch; that was removed
            again (product direction), so nothing installs until <b>Install CLI</b> is clicked.
            Progress reads “Finding the latest CLI release…”, “Downloading the CLI… 42%”,
            “Verifying the CLI’s signature…”, “Setting up this Mac’s identity…”, “CLI installed.
            Starting it…”; a failure “Couldn’t install the CLI while …”. Darkbloom needs macOS 27
            or later (the installer refuses a new install below it, #1505), so there is no
            device-verification step.
          </p>
        </>
      }
      before={
        <>
          <Row caption="First launch, CLI not installed">
            <div className="onboarding-step">
              <SetupBefore backend={backendFor('before', undefined, { status: missing })} />
            </div>
          </Row>
          <Row caption="While the installer runs">
            <div className="onboarding-step">
              <ScanStepBefore
                backend={backendFor('before', undefined, { status: installingBefore })}
                scan={waitingScan}
                proceed={noop}
                explore={noop}
              />
            </div>
          </Row>
          <Row caption="Install fails">
            <div className="onboarding-step">
              <SetupBefore backend={backendFor('before', undefined, { status: baseFailure })} />
            </div>
          </Row>
        </>
      }
      after={
        <>
          <Row caption="First launch, CLI not installed">
            <div className="onboarding-step">
              <SetupAfter backend={backendFor('after', undefined, { status: missingIn('after') })} />
            </div>
          </Row>
          <Row caption="While the installer runs">
            <div className="onboarding-step">
              <SetupAfter
                backend={backendFor('after', undefined, {
                  status: { state: 'installing', message: 'Downloading the CLI… 42%' },
                })}
              />
            </div>
          </Row>
          <Row caption="Install fails">
            <div className="onboarding-step">
              <SetupAfter
                backend={backendFor('after', undefined, {
                  status: {
                    state: 'missing',
                    installFailed: true,
                    message:
                      'Couldn’t install the CLI while downloading it: Bundle hash mismatch — refusing to install possibly-tampered binary.',
                  },
                })}
              />
            </div>
          </Row>
        </>
      }
      log
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1471 follow-up 23892e8a2: the pending link code on This Mac.

const awaitingLink = () => poolSnapshot({}, { linked: false, link: pendingLink() });

export const LinkCodeDisplay: Story = {
  name: '#1471 follow-up: link code on This Mac',
  play: async ({ canvasElement }) => {
    await userEvent.click(pane(canvasElement, 'after').getByRole('button', { name: 'Copy code' }));
  },
  render: () => (
    <Compare
      pr={1471}
      title="This Mac buried the link code inside a sentence"
      wrong={
        <p>
          While a link code was pending, This Mac's Next steps said “Finish linking this Mac ·
          Enter code BLOOM-7Q4K in your browser to attribute this Mac’s earnings to your
          account.”: easy to miss, and awkward to read off while typing it on the link page.
        </p>
      }
      fixed={
        <p>
          Commit <code>23892e8a2</code>: “Enter this code on the link page to attribute this Mac’s
          earnings to your account.”, then the code on its own, large and letter-spaced
          (selectable as one unit), with <b>Copy code</b> (“Copied” after a click; the play step
          clicks it, see the log). <b>Open link page</b> is unchanged.
        </p>
      }
      before={<HealthBefore backend={backendFor('before', awaitingLink())} navigate={noop} />}
      after={<HealthAfter backend={backendFor('after', awaitingLink())} navigate={noop} />}
      log
    />
  ),
};
