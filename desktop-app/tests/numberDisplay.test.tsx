// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { NetworkMilestone } from '../src/renderer/features/home/NetworkMilestone';
import { EarningsTimeline } from '../src/renderer/features/insights/EarningsTimeline';
import { parseInsights } from '../src/renderer/features/insights/types';
import { MemoryHealth } from '../src/renderer/features/machines/overview/MemoryHealth';
import { previewInsights } from '../src/renderer/previewInsights';

afterEach(cleanup);

it('never shows a network total just short of a milestone as reaching it', () => {
  for (const total of ['999960000', '999999999999']) {
    render(
      <NetworkMilestone network={{ total_tokens: total, total_requests: '1', total_macs: 3 }} />,
    );
    const strip = screen.getByRole('region', { name: 'Collective network progress' });
    const bar = screen.getByRole('progressbar');
    expect(strip.querySelectorAll('[role=progressbar] i[data-on]').length).toBeLessThan(24);
    expect(Number(bar.getAttribute('aria-valuenow'))).toBeLessThan(100);
    expect(bar.getAttribute('aria-valuetext')).not.toMatch(/^(1B|1T) of a proposed \1 tokens$/);
    cleanup();
  }
  render(
    <NetworkMilestone
      network={{ total_tokens: '999960000', total_requests: '1', total_macs: 3 }}
    />,
  );
  expect(screen.getByText('999.9M')).toBeVisible();
});

it('labels no scale on an all-zero earnings chart instead of one micro-dollar', () => {
  const fixture = previewInsights('7d');
  const zero = parseInsights({
    ...fixture,
    days: fixture.days.map((day) => ({
      ...day,
      work_micro_usd: '0',
      base_reward_micro_usd: '0',
      jobs: '0',
      completion_tokens: '0',
    })),
  });
  const { container } = render(<EarningsTimeline days={zero.days} metric="earnings" />);
  expect(container).not.toHaveTextContent('$0.000001');
});

it('shows undetected memory as unknown rather than 0 GB', () => {
  render(<MemoryHealth memory={{ total_gb: 0 }} />);
  expect(screen.getByText('Memory unknown')).toBeVisible();
  expect(screen.queryByText(/0\.0 GB/)).not.toBeInTheDocument();
});
