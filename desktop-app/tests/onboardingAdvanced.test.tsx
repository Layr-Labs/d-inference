// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Onboarding } from '../src/renderer/components/Onboarding';
import type { BackendState } from '../src/renderer/useBackend';
import { backendWith, models, operation, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  act: vi.fn(),
  read: vi.fn(),
  openExternal: vi.fn(),
  onNavigate: () => () => {},
}));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const studioOnly = {
  id: 'kimi-k3',
  display_name: 'Kimi K3',
  size_gb: 410,
  downloaded: false,
  serving: false,
  loaded: false,
  eligible: false,
  reason: 'Needs 512 GB of unified memory.',
};

function openAdvanced(state = snapshot({ models: [...models, studioOnly] })) {
  const backend: BackendState = backendWith(state);
  const done = vi.fn();
  render(<Onboarding backend={backend} done={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  fireEvent.click(screen.getByRole('button', { name: 'Advanced' }));
  return { backend, done, panel: screen.getByRole('region', { name: 'Advanced' }) };
}
const pin = (name: RegExp) => screen.getByRole('checkbox', { name });

it('pins models to keep them always on and sends the pins with Autopilot', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  const { done, panel } = openAdvanced();
  expect(screen.getByRole('button', { name: 'Advanced' })).toHaveAttribute('aria-expanded', 'true');
  expect(within(panel).getByRole('heading', { name: 'Keep a model always on' })).toBeVisible();
  const gpt = pin(/GPT-OSS 20B/).closest('label')!;
  expect(gpt).toHaveTextContent('12.1 GB on disk · needs 16.4 GB memory');
  expect(gpt).toHaveTextContent('On this Mac');
  const qwen = pin(/Qwen 3.5 9B/).closest('label')!;
  expect(qwen).toHaveTextContent('6.1 GB download');
  expect(qwen).toHaveTextContent('Downloads on start');
  expect(pin(/Kimi K3/)).toBeDisabled();
  expect(pin(/Kimi K3/).closest('label')).toHaveTextContent('Needs 512 GB of unified memory.');
  fireEvent.click(pin(/Qwen 3.5 9B/));
  fireEvent.click(pin(/GPT-OSS 20B/));
  expect(
    within(panel).getByText('2 kept in memory · at least 22.5 GB of 64 GB memory'),
  ).toBeVisible();
  expect(screen.getByRole('region', { name: 'What happens next' })).toHaveTextContent(
    'Keeps the models you choose in memory and manages the rest as demand changes.',
  );
  fireEvent.click(screen.getByRole('button', { name: /Start serving with Autopilot/ }));
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(api.act).toHaveBeenCalledExactlyOnceWith({
    action: 'autopilot',
    models: ['qwen-3.5-9b', 'gpt-oss-20b'],
    pinned: ['gpt-oss-20b', 'qwen-3.5-9b'],
    downloads: ['qwen-3.5-9b'],
    endpoint: true,
  });
});

it('refuses pins that need more memory than this Mac has', () => {
  openAdvanced(snapshot({ memory: { total_gb: 16 } }));
  fireEvent.click(pin(/GPT-OSS 20B/));
  expect(screen.getByText(/more memory than this Mac has/)).toBeVisible();
  expect(screen.getByRole('button', { name: /Start serving with Autopilot/ })).toBeDisabled();
});

it('says when pins need more models than this Mac keeps in memory at once', () => {
  openAdvanced(snapshot({ memory: { total_gb: 64, max_model_slots: 1 } }));
  fireEvent.click(pin(/GPT-OSS 20B/));
  fireEvent.click(pin(/Qwen 3.5 9B/));
  expect(screen.getByText(/more models than this Mac keeps in memory at once/)).toBeVisible();
  expect(screen.queryByText(/more memory than this Mac has/)).toBeNull();
  expect(screen.getByRole('button', { name: /Start serving with Autopilot/ })).toBeDisabled();
});

it('always contributes: Advanced no longer offers a local-only mode', () => {
  const { panel } = openAdvanced();
  expect(within(panel).queryByRole('heading', { name: 'How this Mac is used' })).toBeNull();
  expect(within(panel).queryByRole('radiogroup')).toBeNull();
  expect(screen.queryByText(/Use models locally/)).toBeNull();
  expect(screen.queryByRole('button', { name: /Start local models/ })).toBeNull();
  expect(screen.getByRole('button', { name: /Start serving with Autopilot/ })).toBeVisible();
});

it('falls back to choosing models manually when the runtime rejects Autopilot', async () => {
  api.act.mockRejectedValue(
    new Error("Error invoking remote method 'darkbloom:act': Error: Unknown action"),
  );
  const backend: BackendState = backendWith(snapshot());
  const done = vi.fn();
  render(<Onboarding backend={backend} done={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  await act(async () =>
    fireEvent.click(screen.getByRole('button', { name: /Start serving with Autopilot/ })),
  );
  expect(screen.getByRole('alert')).toHaveTextContent(
    'Autopilot isn’t available in this version of Darkbloom.',
  );
  expect(done).not.toHaveBeenCalled();
  expect(screen.getByRole('region', { name: 'What happens next' })).toHaveTextContent(
    'Serves GPT-OSS 20B, already on this Mac.',
  );
  expect(screen.getByRole('button', { name: /^Start serving/ })).toBeEnabled();
  fireEvent.click(screen.getByRole('button', { name: /Choose models manually/ }));
  const panel = screen.getByRole('region', { name: 'Advanced' });
  expect(within(panel).getByRole('heading', { name: 'Models to serve' })).toBeVisible();
  expect(pin(/GPT-OSS 20B/)).toBeChecked();
  fireEvent.click(pin(/Qwen 3.5 9B/));
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /^Start serving/ })));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith(
    { action: 'start', models: ['gpt-oss-20b', 'qwen-3.5-9b'], local: false, endpoint: true },
    true,
  );
  expect(done).toHaveBeenCalledOnce();
  expect(api.act).toHaveBeenCalledOnce();
});

// A Hugging Face copy the scan found on disk that the catalog doesn't list. Autopilot can't
// enroll it, so it used to fail start with "could not all be verified".
const diskOnly = {
  ...models[0],
  id: 'mlx-community/gemma-4-26B-A4B-it-qat-4bit',
  display_name: 'mlx-community/gemma-4-26B-A4B-it-qat-4bit',
  network: false,
};

it('starts Autopilot on a network model and never pins a disk-only model', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  openAdvanced(snapshot({ models: [diskOnly, ...models] }));
  expect(pin(/gemma-4-26B-A4B/)).toBeDisabled();
  expect(pin(/gemma-4-26B-A4B/).closest('label')).toHaveTextContent(
    'Not on the Darkbloom network. Runs in Local only.',
  );
  // Onboarding has no local-only mode (#1502), so a disk-only model can't be pinned here at all.
  fireEvent.click(pin(/gemma-4-26B-A4B/));
  expect(pin(/gemma-4-26B-A4B/)).not.toBeChecked();
  fireEvent.click(screen.getByRole('button', { name: /Start serving with Autopilot/ }));
  await waitFor(() =>
    expect(api.act).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'autopilot', models: ['gpt-oss-20b'], pinned: [] }),
    ),
  );
});
