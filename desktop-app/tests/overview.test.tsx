// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

let LocalOverview: typeof import('../src/renderer/features/machines/overview/LocalOverview').LocalOverview;
let TokensChart: typeof import('../src/renderer/features/machines/overview/TokensChart').TokensChart;
let hourlyTokens: typeof import('../src/renderer/features/machines/overview/hourlyTokens').hourlyTokens;
let previewAPI: typeof import('../src/renderer/preview').previewAPI;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ LocalOverview } = await import('../src/renderer/features/machines/overview/LocalOverview'));
  ({ TokensChart } = await import('../src/renderer/features/machines/overview/TokensChart'));
  ({ hourlyTokens } = await import('../src/renderer/features/machines/overview/hourlyTokens'));
  ({ previewAPI } = await import('../src/renderer/preview'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
const health = () => screen.getByRole('region', { name: 'Health' });

it('shows This Mac’s memory, fans, readiness and earnings', async () => {
  render(<LocalOverview backend={await previewBackend()} navigate={vi.fn()} />);
  expect(within(health()).getByRole('status')).toHaveTextContent(
    'Connected and ready for requests',
  );
  for (const text of [
    'Serving GPT-OSS 20B and Gemma 4 26B',
    '19.8 GB of 64.0 GB',
    '16.4 GB active',
    '3.4 GB cache',
    '34.0 GB free to load',
    'Spinning · 2,495 RPM',
    'Left fan 2,480 · Right fan 2,510 RPM · macOS managed',
    '52°C GPU',
  ])
    expect(health()).toHaveTextContent(text);
  expect(within(health()).queryByRole('heading', { name: 'Next steps' })).not.toBeInTheDocument();
  const earnings = screen.getByRole('region', { name: 'This Mac’s earnings' });
  for (const amount of ['$95.40', '$5.62', '$39.10']) expect(earnings).toHaveTextContent(amount);
});

it('distinguishes unread, fanless, unavailable and provider-cooled fans', async () => {
  const backend = await previewBackend();
  const { rerender } = render(
    <LocalOverview backend={{ ...backend, cooling: undefined }} navigate={vi.fn()} />,
  );
  expect(health()).toHaveTextContent('Checking…');
  rerender(
    <LocalOverview
      backend={{ ...backend, cooling: { supported: false, mode: 'automatic', fans: [] } }}
      navigate={vi.fn()}
    />,
  );
  expect(health()).toHaveTextContent('No fansmacOS manages cooling.');
  rerender(
    <LocalOverview
      backend={{
        ...backend,
        cooling: {
          supported: false,
          mode: 'unavailable',
          fans: [],
          error: 'Cooling status unavailable',
        },
      }}
      navigate={vi.fn()}
    />,
  );
  expect(health()).toHaveTextContent('UnavailableCooling status unavailable');
  rerender(
    <LocalOverview
      backend={{
        ...backend,
        cooling: {
          supported: true,
          mode: 'manual',
          temperature: 71.6,
          fans: [{ name: 'Fan', rpm: 4100, max_rpm: 5000 }],
        },
      }}
      navigate={vi.fn()}
    />,
  );
  expect(health()).toHaveTextContent('Spinning · 4,100 RPM82% of max · Provider cooling');
  expect(within(health()).getByRole('img', { name: 'Fan spinning at 4,100 RPM' })).toHaveAttribute(
    'data-animate',
    'true',
  );
  expect(health()).toHaveTextContent('72°C GPU');
});

it('lists next steps with working actions for a stopped, unlinked Mac', async () => {
  const backend = await previewBackend();
  backend.state = {
    ...backend.state!,
    state: 'stopped',
    readiness: 'Ready when you are',
    linked: false,
  };
  const navigate = vi.fn();
  const { rerender } = render(<LocalOverview backend={backend} navigate={navigate} />);
  expect(within(health()).getByRole('status')).toHaveTextContent('Ready when you are');
  expect(health()).toHaveTextContent('Not serving requests');
  const steps = within(health()).getByRole('list');
  expect(
    within(steps)
      .getAllByRole('listitem')
      .map((item) => item.querySelector('strong')!.textContent),
  ).toEqual(['Start providing', 'Link this Mac']);
  fireEvent.click(within(steps).getByRole('button', { name: 'Start providing' }));
  expect(backend.act).toHaveBeenCalledWith({
    action: 'start',
    models: ['gpt-oss-20b', 'gemma-4-26b'],
  });
  fireEvent.click(within(steps).getByRole('button', { name: 'Choose models' }));
  expect(navigate).toHaveBeenCalledWith('models');
  fireEvent.click(within(steps).getByRole('button', { name: 'Link account' }));
  expect(backend.act).toHaveBeenCalledWith({ action: 'link' });
  rerender(<LocalOverview backend={{ ...backend, busy: true }} navigate={navigate} />);
  expect(screen.getByRole('button', { name: 'Start providing' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Choose models' })).toBeEnabled();
});

it('opens the link page while a link code is pending', async () => {
  const open = vi.spyOn(previewAPI, 'openExternal');
  const backend = await previewBackend();
  backend.state = {
    ...backend.state!,
    linked: false,
    link: {
      url: 'https://console.darkbloom.dev/link?code=ABCD-1234',
      code: 'ABCD-1234',
      expires_at: 0,
      state: 'pending',
    },
  };
  render(<LocalOverview backend={backend} navigate={vi.fn()} />);
  expect(health()).toHaveTextContent('Enter code ABCD-1234 in your browser');
  fireEvent.click(screen.getByRole('button', { name: 'Open link page' }));
  expect(open).toHaveBeenCalledWith('link');
});

it('explains a disconnected runtime and repairs it through the native installer', async () => {
  const install = vi.spyOn(previewAPI, 'install');
  const message = 'Could not connect to the runtime. Update or repair the installation.';
  render(
    <LocalOverview
      backend={await previewBackend({ status: { state: 'error', message } })}
      navigate={vi.fn()}
    />,
  );
  expect(within(health()).getByRole('status')).toHaveTextContent(message);
  expect(health()).toHaveTextContent('Status unknown while disconnected');
  fireEvent.click(within(health()).getByRole('button', { name: 'Repair runtime' }));
  expect(install).toHaveBeenCalled();
});

it('shows unreported per-Mac earnings as unknown, never as zero', async () => {
  const backend = await previewBackend();
  const cloud = {
    ...backend.cloud!,
    local_lifetime_micro_usd: undefined,
    local_day_micro_usd: undefined,
  };
  const { rerender } = render(<LocalOverview backend={{ ...backend, cloud }} navigate={vi.fn()} />);
  const earnings = () => screen.getByRole('region', { name: 'This Mac’s earnings' });
  expect(within(earnings()).getAllByText('—')).toHaveLength(2);
  expect(earnings()).toHaveTextContent(
    'Per-Mac totals appear here once your Darkbloom runtime reports them.',
  );
  rerender(
    <LocalOverview
      backend={{ ...backend, cloud, state: { ...backend.state!, linked: false } }}
      navigate={vi.fn()}
    />,
  );
  expect(earnings()).toHaveTextContent('Link this Mac to see what it earns.');
});

it('charts hourly tokens with labelled gaps and keyboard inspection', () => {
  const hour = new Date(2026, 9, 2, 14).getTime() / 1000;
  const samples = [
    { at: hour - 7200, tokens: 0, requests: 0 },
    { at: hour - 7140, tokens: 1500, requests: 2 },
    { at: hour + 60, tokens: 1600, requests: 3 },
    { at: hour + 120, tokens: 2600, requests: 4 },
  ];
  render(<TokensChart now={hour + 300} buckets={hourlyTokens(samples, hour + 300)} />);
  const bars = within(screen.getByRole('group', { name: 'Tokens shared per hour' })).getAllByRole(
    'button',
  );
  expect(bars).toHaveLength(24);
  expect(bars[21]).toHaveAccessibleName(/1,500 tokens · 2 requests · observed 1 of 60 min$/);
  expect(bars[22]).toHaveAccessibleName(/No observations$/);
  expect(bars[23]).toHaveAccessibleName(/now: 1,000 tokens · 1 request · observed 1 of 5 min$/);
  expect(bars[23]).toHaveAttribute('aria-pressed', 'true');
  expect(screen.getByText('2.5K tokens · 3 requests')).toBeVisible();
  bars[23].focus();
  fireEvent.keyDown(bars[23], { key: 'ArrowLeft' });
  expect(bars[22]).toHaveFocus();
  expect(bars[22]).toHaveAttribute('aria-pressed', 'true');
  fireEvent.keyDown(bars[22], { key: 'Home' });
  expect(bars[0]).toHaveFocus();
  expect(bars[0]).toHaveAttribute('tabindex', '0');
  expect(bars[22]).toHaveAttribute('tabindex', '-1');
});
