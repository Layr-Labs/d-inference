// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Machines } from '../src/renderer/features/Machines';
import { previewAPI } from '../src/renderer/preview';
import type { BackendState } from '../src/renderer/useBackend';
vi.mock('../src/renderer/useBackend', () => ({ api: undefined }));
afterEach(cleanup);
async function data(): Promise<BackendState> {
  return {
    state: await previewAPI.read('state'),
    cloud: await previewAPI.read('cloud'),
    status: { state: 'ready' },
    network: undefined,
    cooling: undefined,
    release: undefined,
    releaseHistory: undefined,
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn(),
    refresh: vi.fn(),
  };
}
it('keeps a selected remote Mac view-only and refreshes its observed values', async () => {
  const backend = await data();
  const navigate = vi.fn();
  const { rerender } = render(<Machines backend={backend} navigate={navigate} />);
  fireEvent.click(screen.getByRole('button', { name: 'Select Mac Studio, View only' }));
  expect(screen.getByText('View only · Status and earnings only.')).toBeVisible();
  expect(screen.queryByRole('navigation', { name: 'Machine sections' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Restart' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Manage models' })).not.toBeInTheDocument();
  const updated = {
    ...backend,
    cloud: {
      ...backend.cloud!,
      machines: backend.cloud!.machines.map((mac) => ({
        ...mac,
        status: 'offline',
        earnings_micro_usd: '9000000',
      })),
    },
  };
  rerender(<Machines backend={updated} navigate={navigate} />);
  expect(screen.getByText('$9.00')).toBeVisible();
  expect(screen.getAllByText('offline').length).toBeGreaterThan(0);
  rerender(
    <Machines
      backend={{ ...updated, cloud: { ...updated.cloud!, machines: [] } }}
      navigate={navigate}
    />,
  );
  expect(screen.getByRole('heading', { name: 'My Macs', level: 1 })).toBeVisible();
});
it('keeps the local machine controls and supported operation cancellation in the workspace', async () => {
  const backend = await data();
  const navigate = vi.fn();
  backend.state!.operations = [
    {
      id: 'working',
      action: 'download',
      state: 'running',
      started_at: 1,
      message: 'Downloading a model',
      cancellable: true,
    },
  ];
  render(<Machines backend={backend} navigate={navigate} />);
  fireEvent.click(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' }));
  expect(screen.getByRole('button', { name: 'Stop provider' })).toBeVisible();
  const tabs = screen.getByRole('navigation', { name: 'Machine sections' });
  expect(
    within(tabs)
      .getAllByRole('button')
      .map((button) => button.textContent),
  ).toEqual(['Overview', 'Models', 'Cooling', 'Stats', 'Settings']);
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(backend.act).toHaveBeenCalledWith({ action: 'cancel', operation: 'working' });
  fireEvent.click(screen.getByRole('button', { name: 'Studio' }));
  expect(navigate).toHaveBeenCalledWith('studio');
  fireEvent.click(screen.getByRole('button', { name: 'View earnings' }));
  expect(navigate).toHaveBeenCalledWith('earnings');
});
it('preserves schedule, idle memory, preload, account, and storage settings', async () => {
  render(<Machines backend={await data()} navigate={vi.fn()} route="settings" />);
  expect(screen.getByRole('checkbox', { name: /Use a weekly schedule/ })).toBeVisible();
  expect(screen.getByRole('checkbox', { name: /Preload models/ })).toBeVisible();
  expect(screen.getByRole('combobox', { name: /Memory when idle/ })).toBeVisible();
  expect(screen.getByText('Model storage')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Unlink this Mac' })).toBeVisible();
  expect(screen.getByRole('button', { name: /Save changes/ })).toBeVisible();
});
