import { useState } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Models as ModelsBefore } from '../src/before/desktop-app/src/renderer/features/models/Models';
import { Models as ModelsAfter } from '../src/after/desktop-app/src/renderer/features/models/Models';
import type { Snapshot } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { resetBridges, succeeded } from './support/bridge';
import { backendFor, poolSnapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Models' };
export default meta;
type Story = StoryObj;

const panes = (canvasElement: HTMLElement) => [
  ...canvasElement.querySelectorAll<HTMLElement>('.sb-pane'),
];
const row = (pane: HTMLElement, name: string) =>
  within(within(pane).getByRole('heading', { name }).closest('article') as HTMLElement);

const notSetUp = () => poolSnapshot({ enabled: false, configured: false, selected: [], pinned: [] });

export const AddToPoolBeforeSetup: Story = {
  name: '#1461 Add to pool before Autopilot is set up',
  beforeEach: () => resetBridges({ read: async () => notSetUp() }),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(row(pane, 'Qwen 3.5 9B').getByRole('button', { name: /Add to pool/ }));
  },
  render: () => (
    <Compare
      pr={1461}
      title="“Add to pool” did nothing before Autopilot was set up"
      wrong={
        <p>
          On a Mac that never set up Autopilot, downloaded models offer <b>Add to pool</b>. The
          handler returned early because Autopilot wasn't enabled: no action, no progress, no
          error. The play step clicks it for Qwen 3.5 9B in both panes; compare the logs.
        </p>
      }
      fixed={
        <p>
          It turns Autopilot on with the usual starting models plus this one, as <b>Keep in
          memory</b> already did before setup. <b>Download</b> stays download-only.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', notSetUp())} embedded />}
      after={<ModelsAfter backend={backendFor('after', notSetUp())} embedded />}
      log
      stack
    />
  ),
};

export const DoubleClick: Story = {
  name: '#1461 Double-clicking Keep in memory',
  beforeEach: () =>
    resetBridges({
      // A state read that takes a moment, as it does against the real runtime.
      read: () => new Promise((resolve) => setTimeout(() => resolve(poolSnapshot()), 800)),
      act: async (action) => succeeded(action.action),
    }),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement)) {
      const keep = within(pane).getByRole('button', { name: 'Keep Qwen 3.5 9B in memory' });
      await userEvent.dblClick(keep);
    }
  },
  render: () => (
    <Compare
      pr={1461}
      title="A quick double click sent model actions twice"
      wrong={
        <p>
          Model actions waited for a fresh state read <i>before</i> showing their “working” label,
          and the row only locks once that label exists. The second click of a double click got
          through: two <code>autopilot_pin</code> actions (for Add to pool, two pool refreshes,
          each draining and restarting the runtime).
        </p>
      }
      fixed={
        <p>
          The label is set before anything is awaited and a second click while the action runs is
          ignored. The play step double-clicks <b>Keep in memory</b> in both panes.
        </p>
      }
      before={<ModelsBefore backend={backendFor('before', poolSnapshot())} embedded />}
      after={<ModelsAfter backend={backendFor('after', poolSnapshot())} embedded />}
      log
      stack
    />
  ),
};

const manual = () => poolSnapshot({ enabled: false, phase: 'off' });

export const TurnOnWhileBusy: Story = {
  name: '#1461 Turn on Autopilot while busy',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      pr={1461}
      title="“Turn on Autopilot” stayed clickable during another operation"
      wrong={
        <p>
          While a download or start was running, <b>Apply selection</b> was disabled but{' '}
          <b>Turn on Autopilot</b> only checked its own label, so it could start Autopilot on top
          of the running operation.
        </p>
      }
      fixed={<p>It is disabled while the app or any model action is busy.</p>}
      before={<ModelsBefore backend={backendFor('before', manual(), { busy: true })} embedded />}
      after={<ModelsAfter backend={backendFor('after', manual(), { busy: true })} embedded />}
      stack
    />
  ),
};

function RemovedWhileSelected() {
  const [removed, setRemoved] = useState(false);
  const state: Snapshot = removed
    ? {
        ...manual(),
        models: manual().models.map((model) =>
          model.id === 'qwen-3.5-9b' ? { ...model, downloaded: false } : model,
        ),
      }
    : manual();
  return (
    <>
      <div className="sb-compare" style={{ paddingBottom: 0 }}>
        <button className="button" onClick={() => setRemoved(true)} disabled={removed}>
          Simulate: Qwen 3.5 9B is removed from disk
        </button>
      </div>
      <Compare
        pr={1468}
        title="A removed model stayed selected and was submitted"
        wrong={
          <p>
            With Autopilot off, choose Qwen 3.5 9B (not serving, so it can be removed), then remove
            it. Its checkbox stayed <b>checked but disabled</b>, so it couldn't be cleared, and{' '}
            <b>Apply selection</b> sent a model no longer on disk.
          </p>
        }
        fixed={
          <p>
            The selection only keeps models that are still downloaded. The play step selects Qwen,
            removes it, then applies in both panes.
          </p>
        }
        before={<ModelsBefore backend={backendFor('before', state)} embedded />}
        after={<ModelsAfter backend={backendFor('after', state)} embedded />}
        log
        stack
      />
    </>
  );
}

export const ManualRemovedSelection: Story = {
  name: '#1468 Removed model in manual selection',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('checkbox', { name: 'Select Qwen 3.5 9B' }));
    await userEvent.click(within(canvasElement).getByRole('button', { name: /Simulate/ }));
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('button', { name: /Apply selection/ }));
  },
  render: () => <RemovedWhileSelected />,
};
