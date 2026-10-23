import type { Meta, StoryObj } from '@storybook/react-vite';
import { NetworkMilestone as MilestoneBefore } from '../src/before/desktop-app/src/renderer/features/home/NetworkMilestone';
import { NetworkMilestone as MilestoneAfter } from '../src/after/desktop-app/src/renderer/features/home/NetworkMilestone';
import { EarningsTimeline as TimelineBefore } from '../src/before/desktop-app/src/renderer/features/insights/EarningsTimeline';
import { EarningsTimeline as TimelineAfter } from '../src/after/desktop-app/src/renderer/features/insights/EarningsTimeline';
import { MemoryHealth as MemoryBefore } from '../src/before/desktop-app/src/renderer/features/machines/overview/MemoryHealth';
import { MemoryHealth as MemoryAfter } from '../src/after/desktop-app/src/renderer/features/machines/overview/MemoryHealth';
import { parseInsights } from '../src/after/desktop-app/src/renderer/features/insights/types';
import { previewInsights } from '../src/after/desktop-app/src/renderer/previewInsights';
import { Compare } from './support/Compare';

const meta: Meta = { title: 'Fixes/Home numbers' };
export default meta;
type Story = StoryObj;

const justShort = { total_tokens: '999960000', total_requests: '1', total_macs: 1137 };

export const MilestoneJustShort: Story = {
  name: 'Network total just short of a milestone',
  render: () => (
    <Compare
      pr={1465}
      title="A total just short of a milestone looked reached"
      wrong={
        <p>
          With 999,960,000 network tokens, compact rounding showed <b>1B</b> beside{' '}
          <b>Next milestone 1B</b>, all 24 cells lit and 100% for screen readers, although the
          milestone wasn't reached.
        </p>
      }
      fixed={
        <p>
          The total rounds <i>down</i> toward the milestone (999.9M), and progress is capped below
          completion. Ordinary values keep their rounding (659.1B · 66%).
        </p>
      }
      before={<MilestoneBefore network={justShort} />}
      after={<MilestoneAfter network={justShort} />}
    />
  ),
};

const zeroWeek = () => {
  const fixture = previewInsights('7d');
  return parseInsights({
    ...fixture,
    days: fixture.days.map((day) => ({
      ...day,
      work_micro_usd: '0',
      base_reward_micro_usd: '0',
      jobs: '0',
      completion_tokens: '0',
    })),
  }).days;
};

export const EmptyEarningsChart: Story = {
  name: 'All-zero earnings week',
  render: () => (
    <Compare
      pr={1465}
      title="An empty earnings chart labeled its scale “$0.000001”"
      wrong={
        <p>
          The chart's maximum starts at 1 micro-dollar so bars never divide by zero, and that
          placeholder was printed as the top of the axis on a new account's empty week.
        </p>
      }
      fixed={<p>When every day is zero, the scale is left unlabeled; only “0” remains.</p>}
      before={<TimelineBefore days={zeroWeek()} metric="earnings" />}
      after={<TimelineAfter days={zeroWeek()} metric="earnings" />}
    />
  ),
};

export const UnknownMemory: Story = {
  name: 'Memory the runtime could not detect',
  render: () => (
    <Compare
      pr={1465}
      title="Undetected memory read as 0 GB"
      wrong={
        <p>
          The runtime reports <code>total_gb: 0</code> when hardware detection fails. This Mac's
          Overview printed <b>0.0 GB total</b>; unavailable isn't zero.
        </p>
      }
      fixed={<p>Shows <b>Memory unknown</b>, matching the Mac header.</p>}
      before={<MemoryBefore memory={{ total_gb: 0 }} />}
      after={<MemoryAfter memory={{ total_gb: 0 }} />}
    />
  ),
};
