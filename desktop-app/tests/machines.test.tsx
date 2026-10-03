// @vitest-environment jsdom
import { useState } from 'react';
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Machines } from '../src/renderer/features/Machines';
import type { BackendState } from '../src/renderer/useBackend';
import type { Route } from '../src/shared/contracts';
import { previewBackend } from './previewBackend';
vi.mock('../src/renderer/useBackend', () => ({ api: undefined }));
afterEach(cleanup);

// Holds the selection the way App does: choosing This Mac stores null.
function SelectableMachines({
  backend,
  navigate,
  route = 'machines',
}: {
  backend: BackendState;
  navigate: (route: Route) => void;
  route?: Route;
}) {
  const [machine, setMachine] = useState<string | null>(null);
  return (
    <Machines
      backend={backend}
      navigate={navigate}
      route={route}
      machine={machine}
      onSelect={(id) => setMachine(id === backend.state!.machine.id ? null : id)}
    />
  );
}

it('opens This Mac by default without a fleet overview', async () => {
  render(<SelectableMachines backend={await previewBackend()} navigate={vi.fn()} />);
  const rail = screen.getByRole('complementary', { name: 'Your Macs' });
  expect(
    within(rail)
      .getAllByRole('button')
      .map((button) => button.getAttribute('aria-label')),
  ).toEqual(['Select MacBook Pro, This Mac', 'Select Mac Studio, View only']);
  expect(screen.queryByText('Fleet overview')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  expect(screen.getByRole('heading', { name: /MacBook Pro/, level: 1 })).toHaveTextContent(
    'This Mac',
  );
  expect(screen.getByRole('button', { name: 'Overview' })).toHaveAttribute('aria-current', 'page');
  expect(screen.getByRole('region', { name: 'Health' })).toBeVisible();
});

it('keeps a selected remote Mac view-only and refreshes its observed values', async () => {
  const backend = await previewBackend();
  const navigate = vi.fn();
  const { rerender } = render(<SelectableMachines backend={backend} navigate={navigate} />);
  fireEvent.click(screen.getByRole('button', { name: 'Select Mac Studio, View only' }));
  expect(screen.getByText(/^View only\. Controls for this Mac/)).toBeVisible();
  expect(screen.queryByRole('navigation', { name: 'Machine sections' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Restart' })).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Manage models' })).not.toBeInTheDocument();
  expect(screen.queryByRole('region', { name: 'Health' })).not.toBeInTheDocument();
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
  rerender(<SelectableMachines backend={updated} navigate={navigate} />);
  expect(screen.getByText('$9.00')).toBeVisible();
  expect(screen.getAllByText('offline').length).toBeGreaterThan(0);
  rerender(
    <SelectableMachines
      backend={{ ...updated, cloud: { ...updated.cloud!, machines: [] } }}
      navigate={navigate}
    />,
  );
  expect(screen.getByRole('heading', { name: /MacBook Pro/, level: 1 })).toHaveTextContent(
    'This Mac',
  );
  expect(screen.getByRole('navigation', { name: 'Machine sections' })).toBeVisible();
});

it('applies local sections to This Mac even while a remote Mac is selected', async () => {
  render(
    <Machines
      backend={await previewBackend()}
      navigate={vi.fn()}
      onSelect={vi.fn()}
      route="models"
      machine="remote-studio"
    />,
  );
  expect(screen.getByRole('button', { name: 'Select MacBook Pro, This Mac' })).toHaveAttribute(
    'aria-pressed',
    'true',
  );
  expect(screen.getByRole('heading', { name: 'Models', level: 2 })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Restart' })).toBeVisible();
});

it('keeps the local machine controls and supported operation cancellation in the workspace', async () => {
  const backend = await previewBackend();
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
  render(<SelectableMachines backend={backend} navigate={navigate} />);
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
  fireEvent.click(within(tabs).getByRole('button', { name: 'Cooling' }));
  expect(navigate).toHaveBeenCalledWith('cooling');
});

it('preserves schedule, idle memory, account, and storage settings', async () => {
  render(
    <Machines
      backend={await previewBackend()}
      navigate={vi.fn()}
      onSelect={vi.fn()}
      route="settings"
    />,
  );
  expect(screen.getByRole('switch', { name: /Use a weekly schedule/ })).toBeVisible();
  expect(screen.getByRole('switch', { name: /Keep models loaded/ })).toBeVisible();
  expect(screen.getByRole('spinbutton', { name: 'Free memory after' })).toBeVisible();
  expect(screen.getByText('Model storage')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Unlink this Mac' })).toBeVisible();
  expect(screen.getByRole('button', { name: /Save changes/ })).toBeVisible();
});

it('saves settings without exposing or overwriting the native preload preference', async () => {
  const backend = await previewBackend();
  const settings = backend.state!.settings;
  settings.startup_preload = true;
  render(<Machines backend={backend} navigate={vi.fn()} onSelect={vi.fn()} route="settings" />);
  expect(screen.queryByLabelText(/Preload/i)).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Save changes/ }));
  const [payload] = vi.mocked(backend.act).mock.calls[0];
  expect(payload).toMatchObject({
    action: 'settings',
    revision: settings.revision,
    name: settings.name,
  });
  expect(payload).not.toHaveProperty('startup_preload');
});
