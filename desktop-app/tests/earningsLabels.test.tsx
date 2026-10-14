// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Earnings } from '../src/renderer/features/Earnings';
import { EarningsBreakdown } from '../src/renderer/features/insights/EarningsBreakdown';
import { parseInsights } from '../src/renderer/features/insights/types';
import { previewInsights } from '../src/renderer/previewInsights';
import { poolSnapshot } from './modelsFixtures';
import { backendWith } from './onboardingFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
beforeEach(() => {
  vi.useFakeTimers();
  api.copy.mockResolvedValue(undefined);
  api.read.mockImplementation(async (resource: string) =>
    previewInsights(resource === 'insights-month' ? '30d' : '7d'),
  );
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.resetAllMocks();
});

async function renderEarnings() {
  const state = { ...poolSnapshot(), account: { signed_in: true } };
  const backend = backendWith(state);
  const view = render(<Earnings backend={backend} />);
  await act(async () => {
    await vi.runOnlyPendingTimersAsync();
  });
  return { ...view, backend };
}

it('names models from the catalog and keeps unknown ids readable', () => {
  const data = parseInsights(previewInsights('7d'));
  const models = poolSnapshot().models.filter((model) => model.id !== 'qwen-3.5-9b');
  render(<EarningsBreakdown data={data} metric="earnings" models={models} />);
  expect(screen.getByText('GPT-OSS 20B')).toBeVisible();
  expect(screen.queryByText('gpt-oss-20b')).not.toBeInTheDocument();
  // Not in the catalog: the settled id is still shown.
  expect(screen.getByText('qwen-3.5-9b')).toBeVisible();
});

it('labels the expanded machine breakdown as Macs', () => {
  const data = parseInsights(previewInsights('7d'));
  data.machines = Array.from({ length: 7 }, (_, index) => ({
    ...data.machines[0],
    id: `machine-${index}`,
  }));
  const { container } = render(<EarningsBreakdown data={data} metric="earnings" />);
  fireEvent.click(screen.getByRole('button', { name: 'By Mac' }));
  expect(container.querySelectorAll('details')).toHaveLength(6);
  fireEvent.click(screen.getByRole('button', { name: 'Show all 7 Macs' }));
  expect(container.querySelectorAll('details')).toHaveLength(7);
  expect(screen.getByRole('button', { name: 'Show fewer' })).toBeVisible();
});

it('clears “Copied” 1600 ms after a successful CSV copy', async () => {
  await renderEarnings();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
  await act(async () => {
    await vi.advanceTimersByTimeAsync(1599);
  });
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
  await act(async () => {
    await vi.advanceTimersByTimeAsync(1);
  });
  expect(screen.getByRole('button', { name: 'Copy CSV' })).toBeVisible();
});

it.each(['the same period', 'a new period'])(
  'restarts the full confirmation interval when copying %s',
  async (period) => {
    await renderEarnings();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1500);
    });
    if (period === 'a new period') {
      await act(async () => fireEvent.click(screen.getByRole('button', { name: '30 days' })));
      expect(api.read).toHaveBeenLastCalledWith('insights-month');
    }
    await act(async () =>
      fireEvent.click(
        screen.getByRole('button', {
          name: period === 'a new period' ? 'Copy CSV' : 'Copied',
        }),
      ),
    );
    expect(api.copy).toHaveBeenCalledTimes(2);
    expect(api.copy.mock.lastCall![0].split('\n')).toHaveLength(period === 'a new period' ? 31 : 8);

    await act(async () => {
      await vi.advanceTimersByTimeAsync(100);
    });
    expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1499);
    });
    expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(screen.getByRole('button', { name: 'Copy CSV' })).toBeVisible();
  },
);

it('reports a failed clipboard write without showing confirmation and allows retrying', async () => {
  const { backend } = await renderEarnings();
  api.copy.mockRejectedValueOnce(new Error('Clipboard unavailable'));
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  expect(backend.setError).toHaveBeenCalledExactlyOnceWith('Could not copy earnings history.');
  expect(screen.getByRole('button', { name: 'Copy CSV' })).toBeVisible();
  expect(vi.getTimerCount()).toBe(0);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
});

it('does not restart an existing confirmation when another clipboard write fails', async () => {
  const { backend } = await renderEarnings();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  await act(async () => {
    await vi.advanceTimersByTimeAsync(1500);
  });
  api.copy.mockRejectedValueOnce(new Error('Clipboard unavailable'));
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copied' })));
  expect(backend.setError).toHaveBeenCalledExactlyOnceWith('Could not copy earnings history.');
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
  await act(async () => {
    await vi.advanceTimersByTimeAsync(100);
  });
  expect(screen.getByRole('button', { name: 'Copy CSV' })).toBeVisible();
});

it('cancels the pending confirmation timeout when Earnings unmounts', async () => {
  const { unmount } = await renderEarnings();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  expect(vi.getTimerCount()).toBe(1);
  unmount();
  expect(vi.getTimerCount()).toBe(0);
});

it('does not schedule confirmation if a clipboard write finishes after unmount', async () => {
  const { unmount } = await renderEarnings();
  let finishCopy!: () => void;
  api.copy.mockReturnValueOnce(
    new Promise<void>((resolve) => {
      finishCopy = resolve;
    }),
  );
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy CSV' })));
  unmount();
  await act(async () => finishCopy());
  expect(vi.getTimerCount()).toBe(0);
});
