import { useState } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Studio as StudioBefore } from '../src/before/desktop-app/src/renderer/features/Studio';
import { Studio as StudioAfter } from '../src/after/desktop-app/src/renderer/features/Studio';
import { Cooling as CoolingBefore } from '../src/before/desktop-app/src/renderer/features/Cooling';
import { Cooling as CoolingAfter } from '../src/after/desktop-app/src/renderer/features/Cooling';
import { CoolingControls as ControlsBefore } from '../src/before/desktop-app/src/renderer/features/cooling/CoolingControls';
import { CoolingControls as ControlsAfter } from '../src/after/desktop-app/src/renderer/features/cooling/CoolingControls';
import { Leaderboard as LeaderboardBefore } from '../src/before/desktop-app/src/renderer/features/Leaderboard';
import { Leaderboard as LeaderboardAfter } from '../src/after/desktop-app/src/renderer/features/Leaderboard';
import type { CoolingData, Snapshot } from '../src/after/desktop-app/src/shared/contracts';
import { Compare } from './support/Compare';
import { resetBridges } from './support/bridge';
import { backendFor, poolSnapshot } from './support/fixtures';

const meta: Meta = { title: 'Fixes/Studio, Cooling and Leaderboard' };
export default meta;
type Story = StoryObj;

const panes = (canvasElement: HTMLElement) => [
  ...canvasElement.querySelectorAll<HTMLElement>('.sb-pane'),
];

// The endpoint serves Gemma although GPT-OSS is the first downloaded model.
const endpoint = { base_url: 'http://127.0.0.1:8000/v1', authenticated: true, models: ['gemma-4-26b'] };
const studioState = (running = true): Snapshot =>
  poolSnapshot({}, running ? { endpoint } : { endpoint: undefined });

export const StudioExample: Story = {
  name: '#1463 Studio example request',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('button', { name: /Copy example/ }));
  },
  render: () => (
    <Compare
      pr={1463}
      title="Studio's example request named a model the endpoint wasn't serving"
      wrong={
        <p>
          The model picker defaulted to the first downloaded model (GPT-OSS) and ignored what the
          endpoint actually serves (Gemma). <b>Copy example</b> gave a request that fails, and{' '}
          <b>Apply serving mode</b> would quietly switch models.
        </p>
      }
      fixed={
        <p>
          It defaults to the served model and keeps the example on a served model. The play step
          copies the example in both panes; see the logs and the code block.
        </p>
      }
      before={<StudioBefore backend={backendFor('before', studioState())} embedded />}
      after={<StudioAfter backend={backendFor('after', studioState())} embedded />}
      log
      stack
    />
  ),
};

function KeyAfterStop() {
  const [running, setRunning] = useState(true);
  return (
    <>
      <div className="sb-compare" style={{ paddingBottom: 0 }}>
        <button className="button" onClick={() => setRunning(false)} disabled={!running}>
          Simulate: the local endpoint stops
        </button>
      </div>
      <Compare
        pr={1463}
        title="A revealed API key stayed on screen after the endpoint stopped"
        wrong={
          <p>
            After <b>Reveal</b>, stopping the endpoint left the key visible with <b>Hide</b>{' '}
            disabled. Copy and key-read failures were also unhandled (“Copied” could show when
            nothing was copied).
          </p>
        }
        fixed={
          <p>
            The key is shown only while the endpoint runs; failures show a notice. The play step
            reveals the key in both panes, then stops the endpoint.
          </p>
        }
        before={<StudioBefore backend={backendFor('before', studioState(running))} embedded />}
        after={<StudioAfter backend={backendFor('after', studioState(running))} embedded />}
        stack
      />
    </>
  );
}

export const StudioKey: Story = {
  name: '#1463 Revealed key after the endpoint stops',
  beforeEach: () =>
    resetBridges({
      read: async (resource) => {
        if (resource === 'endpoint-key') return { key: 'sk-local-example-key' };
        throw new Error('Unavailable in Storybook');
      },
    }),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('button', { name: 'Reveal' }));
    await userEvent.click(within(canvasElement).getByRole('button', { name: /Simulate/ }));
  },
  render: () => <KeyAfterStop />,
};

const cooling = (overrides: Partial<CoolingData> = {}): CoolingData => ({
  supported: true,
  enabled: true,
  mode: 'automatic',
  observed_at: Date.now() / 1000,
  temperature: 71,
  fans: [
    { name: 'Left fan', rpm: 2400, max_rpm: 6000 },
    { name: 'Right fan', rpm: 2450, max_rpm: 6000 },
  ],
  speed: 75,
  threshold: 50,
  ...overrides,
});

export const CoolingStale: Story = {
  name: '#1462 Cooling reading five minutes old',
  beforeEach: () => resetBridges(),
  render: () => {
    const stale = cooling({ observed_at: Date.now() / 1000 - 300 });
    return (
      <Compare
        pr={1462}
        title="A five-minute-old cooling reading looked live"
        wrong={
          <p>
            The header correctly said <b>Fan status unavailable</b> for readings older than a
            minute, but the page still showed the old 71° and spinning fans, contradicting itself
            and Home's fan indicator.
          </p>
        }
        fixed={<p>Stale readings show the temperature as — and hide the fan cards.</p>}
        before={<CoolingBefore backend={backendFor('before', poolSnapshot(), { cooling: stale })} embedded />}
        after={<CoolingAfter backend={backendFor('after', poolSnapshot(), { cooling: stale })} embedded />}
      />
    );
  },
};

export const CoolingThreshold: Story = {
  name: '#1462 Threshold set from the CLI',
  beforeEach: () => resetBridges(),
  play: async ({ canvasElement }) => {
    for (const pane of panes(canvasElement))
      await userEvent.click(within(pane).getByRole('button', { name: 'Enable provider cooling' }));
  },
  render: () => {
    const cli = cooling({ threshold: 52, speed: 72.6 });
    return (
      <Compare
        pr={1462}
        title="The threshold select showed 40 °C but submitted 52 °C"
        wrong={
          <p>
            <code>darkbloom fan set --temperature 52</code> is valid, but the select only offers
            5 °C steps, so it displayed 40 °C while <b>Enable provider cooling</b> sent 52. A
            fractional CLI speed (72.6) was sent as-is although the native action takes whole
            numbers.
          </p>
        }
        fixed={
          <p>
            The configured value appears as its own option, and CLI values are rounded and clamped
            to what the native action accepts. The play step clicks Enable in both panes.
          </p>
        }
        before={<ControlsBefore backend={backendFor('before', poolSnapshot(), { cooling: cli })} />}
        after={<ControlsAfter backend={backendFor('after', poolSnapshot(), { cooling: cli })} />}
        log
      />
    );
  },
};

export const LeaderboardLoading: Story = {
  name: '#1467 Leaderboard before rankings load',
  beforeEach: () => resetBridges(),
  render: () => (
    <Compare
      pr={1467}
      title="The Leaderboard said “unavailable” while it was still loading"
      wrong={
        <p>
          Rankings started as an empty list, so before the first read finished the page said{' '}
          <b>Leaderboard unavailable</b>; a genuinely empty result looked the same as a failure.
          The network map also never refreshed on this page and could sit at “Connecting to the
          network” forever.
        </p>
      }
      fixed={
        <p>
          Loading, empty and unavailable are shown separately, and the page now requests the live
          network totals its caption promises. Before: initial state <code>[]</code>; after:{' '}
          <code>undefined</code> until the read settles.
        </p>
      }
      before={<LeaderboardBefore backend={backendFor('before', poolSnapshot(), { leaders: [] })} />}
      after={
        <LeaderboardAfter
          backend={backendFor('after', poolSnapshot(), { leaders: undefined as never })}
        />
      }
    />
  ),
};

export const NetworkFirstReadFailed: Story = {
  name: '#1467 Network statistics fail on first read',
  beforeEach: () => resetBridges(),
  render: () => {
    const network = { error: 'Network statistics are unavailable.' };
    return (
      <Compare
        pr={1467}
        title="A failed first read was called “last known totals”"
        wrong={
          <p>
            If the very first network read failed there were no totals at all, yet the map said{' '}
            <b>Last known totals · reconnecting</b> next to dashes.
          </p>
        }
        fixed={<p>It says <b>Network statistics unavailable · retrying</b>.</p>}
        before={
          <LeaderboardBefore
            backend={backendFor('before', poolSnapshot(), { network, leaderError: 'x' })}
          />
        }
        after={
          <LeaderboardAfter
            backend={backendFor('after', poolSnapshot(), { network, leaderError: 'x' })}
          />
        }
      />
    );
  },
};
