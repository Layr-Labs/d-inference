// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Machine, ReleaseHistory } from '../src/shared/contracts';
import { previewAPI } from '../src/renderer/preview';
import { RemoteOverview } from '../src/renderer/features/machines/overview/RemoteOverview';
import { previewBackend } from './previewBackend';

afterEach(cleanup);

async function studio() {
  const backend = await previewBackend({
    releaseHistory: await previewAPI.read<ReleaseHistory>('release-history'),
  });
  return { backend, machine: backend.cloud!.machines[0] };
}

it('shows the remote Mac’s earnings, 24-hour traffic, hourly chart and models', async () => {
  const { backend, machine } = await studio();
  render(<RemoteOverview machine={machine} backend={backend} />);
  expect(screen.getByRole('status')).toHaveTextContent(/^Online$/);
  expect(screen.getByRole('status').parentElement).toHaveTextContent('Last observed just now');
  expect(screen.getByText('Online since').nextElementSibling).toHaveTextContent(
    /^\d{1,2}:\d{2}\s?[AP]M1[23]h \d+m$/,
  );
  const earnings = screen.getByRole('region', { name: 'Mac Studio’s earnings' });
  for (const amount of ['$186.40', '$4.12', '$7.00']) expect(earnings).toHaveTextContent(amount);
  const day = screen.getByRole('region', { name: 'Past 24 hours' });
  const tokens = machine.tokens_24h!;
  for (const [label, value] of [
    ['Requests', machine.requests_24h!],
    ['Tokens served', tokens.input! + tokens.cached_input! + tokens.output],
    ['Input tokens', tokens.input!],
    ['Cached input tokens', tokens.cached_input!],
    ['Output tokens', tokens.output],
  ] as const)
    expect(within(day).getByText(label).nextElementSibling).toHaveAttribute(
      'title',
      value.toLocaleString('en-US'),
    );
  const bars = within(screen.getByRole('group', { name: 'Tokens shared per hour' })).getAllByRole(
    'button',
  );
  expect(bars).toHaveLength(24);
  expect(bars[9]).toHaveAccessibleName(/No observations$/);
  expect(bars[23]).toHaveAccessibleName(/now: [\d,]+ tokens$/);
  expect(screen.getByText('Last paid work').nextElementSibling).toHaveTextContent('2m ago');
  expect(screen.getByText('Gemma 4 26B')).toBeVisible();
});

it('offers no controls, cooling or memory internals for a remote Mac', async () => {
  const { backend, machine } = await studio();
  const { container } = render(<RemoteOverview machine={machine} backend={backend} />);
  const chart = screen.getByRole('group', { name: 'Tokens shared per hour' });
  for (const button of screen.getAllByRole('button')) expect(chart).toContainElement(button);
  expect(container.querySelectorAll('input, select, textarea, a, form')).toHaveLength(0);
  expect(screen.getByText(/^View only\./)).toBeVisible();
  for (const internal of [/fan/i, /cooling/i, /GPU/, /free to load/, /Manage models/])
    expect(container).not.toHaveTextContent(internal);
});

it('shows a dash for every figure the account projection does not report yet', async () => {
  const { backend } = await studio();
  const machine: Machine = {
    id: 'remote-mini',
    name: 'Mac mini',
    chip: 'Apple M4 Pro',
    memory_gb: 48,
    status: 'online',
    observed_at: backend.state!.observed_at - 30,
    models: [],
  };
  const { container } = render(<RemoteOverview machine={machine} backend={backend} />);
  expect(
    within(screen.getByRole('region', { name: 'Mac mini’s earnings' })).getAllByText('—'),
  ).toHaveLength(6);
  expect(
    within(screen.getByRole('region', { name: 'Past 24 hours' })).getAllByText('—'),
  ).toHaveLength(5);
  for (const label of ['Provider version', 'Last paid work', 'Online since'])
    expect(screen.getByText(label).nextElementSibling).toHaveTextContent('—');
  expect(screen.queryByRole('group', { name: 'Tokens shared per hour' })).not.toBeInTheDocument();
  expect(screen.getByText('No serving models reported')).toBeVisible();
  expect(container).not.toHaveTextContent('$0.00');
});

it('flags a silent or offline Mac and a provider below the minimum version', async () => {
  const { backend, machine } = await studio();
  const now = backend.state!.observed_at;
  const { rerender } = render(
    <RemoteOverview
      machine={{ ...machine, observed_at: now - 3 * 3600, version: '0.9.14' }}
      backend={backend}
    />,
  );
  const status = screen.getByRole('status');
  expect(status).toHaveTextContent('Not reportinglast reported online');
  expect(status.parentElement).toHaveTextContent('Last observed 3h ago');
  expect(status.querySelector('i')).toHaveAttribute('data-presence', 'stale');
  expect(screen.getByText('Online since').nextElementSibling).toHaveTextContent('—');
  expect(screen.getByText('Update required')).toBeVisible();
  expect(screen.getByRole('group', { name: 'Tokens shared per hour' })).not.toHaveTextContent(
    'Now',
  );
  rerender(<RemoteOverview machine={{ ...machine, status: 'offline' }} backend={backend} />);
  expect(screen.getByRole('status')).toHaveTextContent(/^Offline/);
  expect(screen.getByRole('status').querySelector('i')).toHaveAttribute('data-presence', 'offline');
  expect(screen.queryByText('Update required')).not.toBeInTheDocument();
});
