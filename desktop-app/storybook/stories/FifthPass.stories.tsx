import type { ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import AppBefore from '../src/before/desktop-app/src/renderer/App';
import AppAfter from '../src/after/desktop-app/src/renderer/App';
import { Onboarding as OnboardingBefore } from '../src/before/desktop-app/src/renderer/components/Onboarding';
import { Onboarding as OnboardingAfter } from '../src/after/desktop-app/src/renderer/components/Onboarding';
import { RuntimeSetup as SetupBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { RuntimeSetup as SetupAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/RuntimeSetup';
import { ScanStep as ScanStepBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/ScanStep';
import { ScanStep as ScanStepAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/ScanStep';
import { evaluateEligibility as eligibilityBefore } from '../src/before/desktop-app/src/renderer/components/onboarding/eligibility';
import { evaluateEligibility as eligibilityAfter } from '../src/after/desktop-app/src/renderer/components/onboarding/eligibility';
import { LinkPanel } from '../src/after/desktop-app/src/renderer/components/onboarding/LinkPanel';
import { Startup } from '../src/after/desktop-app/src/renderer/components/Startup';
import { HealthBar } from '../src/after/desktop-app/src/renderer/features/machines/overview/HealthBar';
import type { DesktopStatus, Snapshot } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { AtRoute, shellFixtures } from './support/Shell';
import { resetBridges, type Version } from './support/bridge';
import { backendFor, poolSnapshot, snapshot } from './support/fixtures';

const meta: Meta = { title: 'Fifth pass/Policy and polish', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const noop = () => {};
const now = () => Math.floor(Date.now() / 1000);
const older = '26.5';
const pane = (canvasElement: HTMLElement, version: Version) =>
  within(canvasElement.querySelector<HTMLElement>(`.sb-panes > .sb-${version}`)!);
const row = (canvasElement: HTMLElement, version: Version, caption: string) =>
  within(
    canvasElement.querySelector<HTMLElement>(`.sb-panes > .sb-${version} [data-row="${caption}"]`)!,
  );

/** A captioned state inside a pane; `data-row` lets the play step find it. */
const Row = ({ caption, children, short, width }: { caption: string; children: ReactNode; short?: boolean; width?: number }) => (
  <div data-row={caption}>
    <h3 style={{ margin: '18px 0 8px', fontSize: 13, opacity: 0.8 }}>{caption}</h3>
    <div className={short ? 'sb-short' : undefined} style={width ? { maxWidth: width } : undefined}>
      {children}
    </div>
  </div>
);

// Home's macOS notice stays dismissed for the session once closed; every story starts with it.
const promptKey = 'darkbloom.macos-prompt-dismissed';
const freshPrompt = () => {
  try {
    sessionStorage.removeItem(promptKey);
  } catch {
    // Storage blocked: the notice shows anyway.
  }
};

// ---------------------------------------------------------------------------------------------
// #1506: macOS 27 or later for new providers.

const missingBefore: DesktopStatus = { state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' };
const missingAfter: DesktopStatus = { state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' };
const on = (macosVersion: string) => ({ system: { macosVersion } });

export const MacosFirstScreen: Story = {
  name: '#1506 First screen on macOS 26.5, no CLI',
  play: async ({ canvasElement }) => {
    await userEvent.click(
      row(canvasElement, 'after', 'macOS 26.5, CLI not installed').getByRole('button', { name: /Open Software Update/ }),
    );
  },
  render: () => (
    <Compare
      pr={1506}
      title="A new Mac on macOS 26 was offered Install CLI, which the installer then refuses"
      wrong={
        <p>
          Darkbloom no longer accepts new providers below macOS 27, and the CLI installer refuses
          a new install there (#1505). The app didn't know: on a Mac with no CLI it still offered
          the install (here the base tree: Welcome first, then the install screen after{' '}
          <b>Start</b>; since #1502 the install screen is step 1), so the user clicked, waited for
          the installer to fail, and had no way to update macOS from the app. Both panes: macOS
          26.5, status <code>missing</code>.
        </p>
      }
      fixed={
        <p>
          The app reads the macOS version (<code>api.system()</code>). With no CLI below macOS
          27, step 1 is “Darkbloom needs macOS 27 or later” (“New Macs can join Darkbloom on macOS
          27 or later. This Mac runs macOS 26.5. Update macOS, then reopen Darkbloom.”) with{' '}
          <b>Open Software Update</b> and no Install CLI. A Mac that already has the CLI, and a
          returning user reinstalling it, are existing providers and aren't gated (last row). The
          play step clicks <b>Open Software Update</b>; the log shows{' '}
          <code>openSoftwareUpdate</code> (System Settings › Software Update, a fixed URL in the
          main process).
        </p>
      }
      before={
        <>
          <Row caption="macOS 26.5, CLI not installed" short>
            <OnboardingBefore backend={backendFor('before', undefined, { status: missingBefore })} done={noop} />
          </Row>
          <Row caption="The base install screen (after Start)">
            <div className="onboarding-step">
              <SetupBefore backend={backendFor('before', undefined, { status: missingBefore })} />
            </div>
          </Row>
        </>
      }
      after={
        <>
          <Row caption="macOS 26.5, CLI not installed" short>
            <OnboardingAfter
              backend={backendFor('after', undefined, { status: missingAfter, ...on(older) })}
              done={noop}
            />
          </Row>
          <Row caption="The same Mac on macOS 27.0 (unchanged)">
            <div className="onboarding-step">
              <SetupAfter backend={backendFor('after', undefined, { status: missingAfter })} />
            </div>
          </Row>
          <Row caption="Returning user reinstalling on macOS 26.5 (not gated)">
            <Startup backend={backendFor('after', undefined, { status: missingAfter, ...on(older) })} />
          </Row>
        </>
      }
      stack
      log
    />
  ),
};

const unlinked = () => snapshot({ linked: false });

function ScanVerdictBefore({ state }: { state: Snapshot }) {
  const result = eligibilityBefore(state);
  const frame = { revealed: result.checks.length, resolved: result.checks.length, phase: 'verdict' as const };
  return (
    <div className="onboarding-step">
      <ScanStepBefore
        backend={backendFor('before', state)}
        scan={{ result, frame, finish: noop, settled: true, blocked: false, recheck: async () => {} }}
        proceed={noop}
        explore={noop}
      />
    </div>
  );
}

function ScanVerdictAfter({ state, macos }: { state: Snapshot; macos: string }) {
  const result = eligibilityAfter(state, macos);
  const frame = { revealed: result.checks.length, resolved: result.checks.length, phase: 'verdict' as const };
  return (
    <div className="onboarding-step">
      <ScanStepAfter
        backend={backendFor('after', state, on(macos))}
        scan={{ result, frame, finish: noop, settled: true, recheck: async () => {} }}
        next="link your account"
        proceed={noop}
        explore={noop}
      />
    </div>
  );
}

export const MacosCheckThisMac: Story = {
  name: '#1506 Check this Mac on macOS 26.5',
  play: async ({ canvasElement }) => {
    await userEvent.click(pane(canvasElement, 'after').getByRole('button', { name: /Open Software Update/ }));
  },
  render: () => (
    <Compare
      pr={1506}
      title="Check this Mac passed a Mac that can't join on its macOS"
      wrong={
        <p>
          The check had no macOS row: without a runtime-reported <code>eligibility</code>, the
          renderer derives only Apple silicon and memory, so a 64 GB M4 Max on macOS 26.5 read
          “This Mac is eligible” and moved on to linking. Both panes: the check's verdict for the
          same snapshot (no <code>eligibility</code>), held still as <code>useMacScan</code>{' '}
          reports it.
        </p>
      }
      fixed={
        <p>
          <code>evaluateEligibility(snapshot, macosVersion)</code> adds a <code>macos</code> check
          when the report has none (a runtime's own is kept; an unknown version adds none). On
          26.5 it fails: “Darkbloom needs macOS 27 or later for new providers. Update macOS in
          Software Update.”, the verdict is ineligible (never asked to link), and{' '}
          <b>Open Software Update</b> sits above the waitlist, since it's the one reason the Mac
          can fix itself. The play step clicks it.
        </p>
      }
      before={<ScanVerdictBefore state={unlinked()} />}
      after={<ScanVerdictAfter state={unlinked()} macos={older} />}
      log
    />
  ),
};

export const MacosThisMacShell: Story = {
  name: '#1506 This Mac on macOS 26.5 (in the app)',
  beforeEach: () => shellFixtures({ macosVersion: older }),
  play: async ({ canvasElement }) => {
    const after = pane(canvasElement, 'after');
    await userEvent.click(await after.findByRole('button', { name: /Open Software Update/ }, { timeout: 8000 }));
  },
  render: () => (
    <Compare
      pr={1506}
      title="An existing provider on macOS 26 was never told to update macOS"
      wrong={
        <p>
          The real <code>App</code> from each tree on its development-preview fixtures (serving,
          linked), opened at My Macs › This Mac, with the main process reporting macOS 26.5.
          Nothing mentions macOS: the Mac keeps serving (the coordinator decides whether a
          grandfathered provider stays authorized), but the user learns only when it stops.
        </p>
      }
      fixed={
        <p>
          Next steps gain <b>Update macOS</b> (“Darkbloom needs macOS 27 or later. Update macOS to
          keep serving.”) with <b>Open Software Update</b> (clicked by the play step; see the
          log). It's advice: the tone stays green “Ready to serve” and it's never the headline.
          The CLI's own steps now say CLI, not runtime (“Install the Darkbloom CLI”,{' '}
          <b>Install CLI</b> / <b>Repair CLI</b>). Scroll inside a pane for the rest.
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
      log
    />
  ),
};

export const MacosHomeShell: Story = {
  name: '#1506 Home notice on macOS 26.5 (in the app)',
  beforeEach: () => {
    freshPrompt();
    const restore = shellFixtures({ macosVersion: older });
    return () => {
      restore();
      freshPrompt();
    };
  },
  render: () => (
    <Compare
      pr={1506}
      title="Home didn't mention that this Mac's macOS is too old"
      wrong={
        <p>
          The real <code>App</code> from each tree at Home, the main process reporting macOS 26.5.
          No prompt anywhere.
        </p>
      }
      fixed={
        <p>
          A notice under the header: “Darkbloom needs macOS 27 or later. Update macOS to keep
          serving.” with <b>Open Software Update</b> and a close button. Closing it hides it
          until Darkbloom is next opened (<code>sessionStorage</code>); This Mac's step stays.
          Serving is untouched (<b>Stop serving</b> still works). The dismissal is played in{' '}
          <i>Flows › Status checks › This Mac: macOS 26 Mac</i>.
        </p>
      }
      before={<AppBefore />}
      after={<AppAfter />}
      height={760}
      stack
    />
  ),
};

// ---------------------------------------------------------------------------------------------
// #1507: Home's Mac cards read as controls; a stopped This Mac offers Start serving.

const stoppedThisMac = (state: Snapshot): Snapshot => ({
  ...state,
  state: 'stopped',
  models: state.models.map((model) => ({ ...model, loaded: false })),
});

/**
 * Give Mac Studio's card keyboard focus in the After pane (its focus ring) and scroll the canvas
 * to that pane's Your Macs. The panes have no fixed height, so the sidebar runs beside the page.
 */
async function showYourMacs(canvasElement: HTMLElement) {
  await pane(canvasElement, 'before').findByRole('button', { name: 'Open Mac Studio' }, { timeout: 8000 });
  const studio = await pane(canvasElement, 'after').findByRole('button', { name: 'Open Mac Studio' }, { timeout: 8000 });
  studio.focus({ preventScroll: true });
  studio.closest('section')?.scrollIntoView({ block: 'center' });
}

const macCards = (stopped: boolean): Story => ({
  name: stopped ? '#1507 Your Macs, This Mac stopped (in the app)' : '#1507 Your Macs, This Mac serving (in the app)',
  beforeEach: () => shellFixtures(stopped ? { snapshot: stoppedThisMac } : {}),
  play: async ({ canvasElement }) => showYourMacs(canvasElement),
  render: () => (
    <Compare
      pr={1507}
      title={
        stopped
          ? "Home's Mac cards looked like a status widget, and a stopped This Mac didn't say how to start"
          : 'While This Mac serves, its card shows live status and no call to action'
      }
      wrong={
        <p>
          Each Mac under <i>Your Macs</i> is a button that opens it, but it was drawn as a plain
          table row (name, status, models, earnings) with only a faint hover, so it read as a
          readout. {stopped ? 'A stopped This Mac said “Stopped” and nothing else.' : ''} Both
          panes: the real <code>App</code> on the development-preview fixtures
          {stopped ? ', with This Mac stopped' : ' (This Mac serving)'} and Mac Studio (view only)
          online. Your Macs is near the bottom of each pane; the play step scrolls to the After
          pane's.
        </p>
      }
      fixed={
        <p>
          Every card gets a trailing chevron that brightens and nudges on hover and focus, a
          pressed state, and an inset focus ring the sideways-scrolling list doesn't clip (the
          play step focuses Mac Studio's card in the After pane).{' '}
          {stopped ? (
            <>
              A stopped This Mac adds a strip under its card: “This Mac isn't serving requests.
              Choose models to start earning.” with <b>Start serving</b>, the header's action
              (opens Models; disabled while busy). It sits beside the open button, not inside it.
            </>
          ) : (
            <>
              Serving, starting, finishing requests or stale: no call to action (the header
              handles those, #1487). A view-only Mac never offers to start.
            </>
          )}
        </p>
      }
      before={<AppBefore />}
      after={<AppAfter />}
      stack
    />
  ),
});

export const HomeMacCardsStopped = macCards(true);
export const HomeMacCardsServing = macCards(false);

// ---------------------------------------------------------------------------------------------
// CSS follow-ups: each pane runs the same After component; the Before pane undoes the one rule
// the follow-up commit added (the base tree has neither the large code nor Get help).

const pendingLink = (): NonNullable<Snapshot['link']> => ({
  url: 'https://example.invalid/link',
  code: 'BLOOM-7Q4K',
  expires_at: now() + 900,
  state: 'pending',
});
const awaitingLink = () => poolSnapshot({}, { linked: false, link: pendingLink() });
const undo = (rule: string) => <style>{rule}</style>;

const codeRows = (version: Version) => (
  <>
    {version === 'before' && undo('.sb-before strong[aria-label^="Link code"] { white-space: normal; }')}
    <Row caption="Link panel (onboarding, Link this Mac dialog), 300 px column" width={300}>
      <LinkPanel link={pendingLink()} cancel={noop} />
    </Row>
    <Row caption="This Mac › Finish linking this Mac, 290 px column" width={290}>
      <HealthBar backend={backendFor(version, awaitingLink())} navigate={noop} />
    </Row>
  </>
);

export const LinkCodeOneLine: Story = {
  name: '#1499 / #1471 follow-ups: link code on one line',
  render: () => (
    <Compare
      pr={1499}
      title="In a narrow column the link code broke at its hyphen (“BLOOM-” / “7Q4K”)"
      wrong={
        <p>
          The code is typed on the link page, so a line break at its hyphen invites a typo. At
          narrow widths both large codes wrapped: the link panel's (#1499, onboarding and Models'{' '}
          <i>Link this Mac</i> dialog) and This Mac's <i>Finish linking</i> step (#1471). Before
          pane: the integration build's components with the follow-ups' one rule undone.
        </p>
      }
      fixed={
        <p>
          <code>white-space: nowrap</code> on each code (<code>f6fcfc52a</code> on #1499,{' '}
          <code>8de128803</code> on #1471): the code stays whole. At these deliberately narrow
          widths the space comes from elsewhere: This Mac's <b>Copy code</b> wraps to two lines,
          and the link panel's <b>Open link page</b> sticks out past the panel's right edge (its
          row doesn't wrap; it already overflowed slightly before). 300 px is a little narrower
          than the panel gets in the app (about 340 px in onboarding and the dialog at the
          minimum 940 px window).
        </p>
      }
      before={codeRows('before')}
      after={codeRows('after')}
      labels={{ before: 'Before · follow-ups’ nowrap undone', after: 'After · #1499 f6fcfc52a, #1471 8de128803' }}
    />
  ),
};

const failedInstall: DesktopStatus = {
  state: 'missing',
  installFailed: true,
  message: 'Couldn’t install the CLI while downloading it: Bundle hash mismatch — refusing to install possibly-tampered binary.',
};

const helpRows = (version: Version) => (
  <>
    {version === 'before' && undo('.sb-before .get-help { margin-top: 0; }')}
    <Row caption="Onboarding step 1, install failed" width={420}>
      <div className="onboarding-step">
        <SetupAfter backend={backendFor(version, undefined, { status: failedInstall })} />
      </div>
    </Row>
    <Row caption="Returning user, reinstall failed">
      <Startup backend={backendFor(version, undefined, { status: failedInstall })} />
    </Row>
  </>
);

export const GetHelpSpacing: Story = {
  name: '#1503 follow-up: Get help spaced from Retry',
  render: () => (
    <Compare
      pr={1503}
      title="After a failed install, Get help sat almost against the Retry button"
      wrong={
        <p>
          #1503 added <b>Get help</b> under a failed install, right below the full-width{' '}
          <b>Retry</b> with no space between them. Before pane: the integration build's{' '}
          <code>RuntimeSetup</code> with the follow-up's rule undone (the base tree has no Get
          help at all).
        </p>
      }
      fixed={
        <p>
          Commit <code>5b74b4612</code>: the link's paragraph gets <code>.get-help</code> with{' '}
          <code>margin-top: 14px</code>, in onboarding and on the returning-user startup screen.
        </p>
      }
      before={helpRows('before')}
      after={helpRows('after')}
      labels={{ before: 'Before · follow-up’s spacing undone', after: 'After · #1503 5b74b4612' }}
    />
  ),
};
