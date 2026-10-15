import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Settings as SettingsBefore } from '../src/before/desktop-app/src/renderer/features/Settings';
import { Settings as SettingsAfter } from '../src/after/desktop-app/src/renderer/features/Settings';
import { Home as HomeBefore } from '../src/before/desktop-app/src/renderer/features/Home';
import { Home as HomeAfter } from '../src/after/desktop-app/src/renderer/features/Home';
import { FleetMacs as FleetBefore } from '../src/before/desktop-app/src/renderer/features/home/FleetMacs';
import { FleetMacs as FleetAfter } from '../src/after/desktop-app/src/renderer/features/home/FleetMacs';
import { ExpandableModelList as ListBefore } from '../src/before/desktop-app/src/renderer/features/models/ExpandableModelList';
import { ExpandableModelList as ListAfter } from '../src/after/desktop-app/src/renderer/features/models/ExpandableModelList';
import { EarningsBreakdown as BreakdownBefore } from '../src/before/desktop-app/src/renderer/features/insights/EarningsBreakdown';
import { EarningsBreakdown as BreakdownAfter } from '../src/after/desktop-app/src/renderer/features/insights/EarningsBreakdown';
import { parseInsights } from '../src/after/desktop-app/src/renderer/features/insights/types';
import { previewInsights } from '../src/after/desktop-app/src/renderer/previewInsights';
import type { Machine } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, poolSnapshot, previewBackend, snapshot } from './support/fixtures';

const meta: Meta = { title: 'Second pass/Behavior', beforeEach: () => resetBridges() };
export default meta;
type Story = StoryObj;

const panes = (canvasElement: HTMLElement) => [
  ...canvasElement.querySelectorAll<HTMLElement>('.sb-pane'),
];

export const UnlinkConfirmation: Story = {
  name: '#1471 Unlinking this Mac',
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('button', { name: 'Unlink this Mac' }));
  },
  render: () => (
    <Compare
      pr={1471}
      title="Unlinking happened on a single click"
      wrong={
        <p>
          <b>Unlink this Mac</b> sent the unlink immediately, unlike Remove model or Turn off
          Autopilot, which confirm. The play step clicks it once in both panes; compare the logs.
        </p>
      }
      fixed={<p>A confirmation dialog: <b>Keep linked</b> or <b>Unlink this Mac</b>.</p>}
      before={<SettingsBefore backend={backendFor('before', snapshot({ linked: true }))} embedded />}
      after={<SettingsAfter backend={backendFor('after', snapshot({ linked: true }))} embedded />}
      log
      height={560}
    />
  ),
};

export const LinkPending: Story = {
  name: '#1471 Link account while a link is in progress',
  loaders: [async () => ({ backend: await previewBackend() })],
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement)) {
      const button = within(pane).getByRole('button', { name: 'Link account' });
      if (!(button as HTMLButtonElement).disabled) {
        await userEvent.click(button);
        await userEvent.click(button);
      }
    }
  },
  render: (_, { loaded }) => {
    const base = loaded.backend.state!;
    const state = {
      ...base,
      linked: false,
      operations: [
        {
          id: 'link-1',
          action: 'link' as const,
          state: 'running' as const,
          started_at: Date.now() / 1000,
          message: 'Linking…',
          cancellable: true,
        },
      ],
    };
    return (
      <Compare
        pr={1471}
        title="Each click on “Link account” started another link request"
        wrong={
          <p>
            Home's footer kept <b>Link account</b> enabled while a link was in progress (and next
            to its code). The play step clicks it twice in both panes.
          </p>
        }
        fixed={<p>Disabled while linking, and hidden once the link code is shown.</p>}
        before={<HomeBefore backend={backendFor('before', state)} navigate={() => {}} openMachine={() => {}} />}
        after={<HomeAfter backend={backendFor('after', state)} navigate={() => {}} openMachine={() => {}} />}
        log
        height={420}
      />
    );
  },
};

export const InvalidSchedule: Story = {
  name: '#1473 Saving a schedule the runtime rejects',
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement)) {
      const scope = within(pane);
      await userEvent.click(scope.getByRole('switch', { name: /Use a weekly schedule/ }));
      for (const day of ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) await userEvent.click(scope.getByText(day));
      const save = scope.getByRole('button', { name: /Save changes/ });
      if (!(save as HTMLButtonElement).disabled) await userEvent.click(save);
    }
  },
  render: () => (
    <Compare
      pr={1473}
      title="An invalid weekly schedule was saved anyway"
      wrong={
        <p>
          With the schedule on and no days selected, <b>Save changes</b> stayed enabled and sent a
          schedule the runtime rejects, so the user only saw a generic failure. Save was also
          enabled on an untouched form.
        </p>
      }
      fixed={
        <p>
          The runtime's rules are checked first: the problem is explained under the schedule and
          Save is disabled. The play step turns the schedule on, clears Mon–Fri and tries Save.
        </p>
      }
      before={<SettingsBefore backend={backendFor('before', snapshot())} embedded />}
      after={<SettingsAfter backend={backendFor('after', snapshot())} embedded />}
      log
      height={720}
    />
  ),
};

const oneMac = [
  {
    id: 'this-mac',
    name: 'MacBook Pro',
    chip: 'Apple M4 Max',
    memory_gb: 64,
    status: 'running',
    models: [],
  } as unknown as Machine,
];

export const Pluralization: Story = {
  name: '#1472 Counts of one',
  render: () => (
    <Compare
      pr={1472}
      title="“1 Macs” and “Show 1 more models”"
      wrong={
        <p>
          Several labels appended a fixed plural, so every single-Mac user saw <b>1 Macs</b>, and
          lists offered <b>Show 1 more models</b> (also “1 downloads”, “1 requests”, “1 tokens”).
        </p>
      }
      fixed={<p>A shared <code>plural()</code> helper agrees the noun with the count.</p>}
      before={
        <>
          <FleetBefore machines={oneMac} localID="this-mac" onOpen={() => {}} />
          <ListBefore items={[1, 2, 3, 4]}>{(n) => <p key={n}>Model {n}</p>}</ListBefore>
        </>
      }
      after={
        <>
          <FleetAfter machines={oneMac} localID="this-mac" onOpen={() => {}} />
          <ListAfter items={[1, 2, 3, 4]}>{(n) => <p key={n}>Model {n}</p>}</ListAfter>
        </>
      }
    />
  ),
};

export const EarningsLabels: Story = {
  name: '#1476 Earnings breakdown labels',
  render: () => {
    const data = parseInsights(previewInsights('7d'));
    return (
      <Compare
        pr={1476}
        title="Earnings named models by raw id"
        wrong={
          <p>
            The breakdown showed <b>gpt-oss-20b</b> where every other screen says <b>GPT-OSS 20B</b>
            , and Copy CSV's “Copied” never reset.
          </p>
        }
        fixed={
          <p>
            Catalog names when the model is known (falling back to the settled id), “Show all N
            Macs”, and Copied resets after a moment.
          </p>
        }
        before={<BreakdownBefore data={data} metric="earnings" />}
        after={<BreakdownAfter data={data} metric="earnings" models={poolSnapshot().models} />}
      />
    );
  },
};

export const PlainCopy: Story = {
  name: '#1477 Implementation terms in Settings',
  render: () => (
    <Compare
      pr={1477}
      title="Settings said “Managed by the Swift backend”"
      wrong={
        <p>
          User-facing text exposed implementation terms (“Swift backend”, “changed in the
          backend”, “Native load allowance”) and dialogs said “pins” while the controls say “Keep
          in memory”. Look under <b>Model storage</b>.
        </p>
      }
      fixed={<p>Plain language: “Managed by the Darkbloom runtime”, and “kept in memory” throughout.</p>}
      before={<SettingsBefore backend={backendFor('before', snapshot())} embedded />}
      after={<SettingsAfter backend={backendFor('after', snapshot())} embedded />}
      height={560}
    />
  ),
};
