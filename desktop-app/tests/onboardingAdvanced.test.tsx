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
  expect(within(panel).getByText('2 pinned · at least 16.4 GB of 64 GB memory')).toBeVisible();
  expect(screen.getByRole('region', { name: 'What happens next' })).toHaveTextContent(
    'Keeps pinned models loaded and manages the rest as demand changes.',
  );
  fireEvent.click(screen.getByRole('button', { name: /Start serving with Autopilot/ }));
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(api.act).toHaveBeenCalledExactlyOnceWith({
    action: 'autopilot',
    models: ['qwen-3.5-9b', 'gpt-oss-20b'],
    pinned: ['gpt-oss-20b', 'qwen-3.5-9b'],
    endpoint: true,
  });
});

it('refuses pins that need more memory than this Mac has', () => {
  openAdvanced(snapshot({ memory: { total_gb: 16 } }));
  fireEvent.click(pin(/GPT-OSS 20B/));
  expect(screen.getByText(/more memory than this Mac has/)).toBeVisible();
  expect(screen.getByRole('button', { name: /Start serving with Autopilot/ })).toBeDisabled();
});

it('runs locally only with at least one pinned model and no account', async () => {
  const { backend, done } = openAdvanced(snapshot({ linked: false }));
  fireEvent.click(screen.getByRole('radio', { name: /Use models locally/ }));
  const start = screen.getByRole('button', { name: /Start local models/ });
  expect(start).toBeDisabled();
  expect(screen.getByText('Pin a model to run it locally.')).toBeVisible();
  fireEvent.click(pin(/GPT-OSS 20B/));
  expect(start).toBeEnabled();
  expect(screen.getByText('Local only doesn’t need a Darkbloom account.')).toBeVisible();
  await act(async () => fireEvent.click(start));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith(
    { action: 'start', models: ['gpt-oss-20b'], local: true, endpoint: true },
    true,
  );
  expect(done).toHaveBeenCalledOnce();
  expect(api.act).not.toHaveBeenCalled();
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
