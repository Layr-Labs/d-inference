// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Snapshot } from '../src/shared/contracts';
import type { BackendState } from '../src/renderer/useBackend';
import { previewAPI } from '../src/renderer/preview';
import App from '../src/renderer/App';
import { Onboarding } from '../src/renderer/components/Onboarding';
import { backendWith, models, operation, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  act: vi.fn(),
  read: vi.fn(),
  openExternal: vi.fn(),
  onNavigate: () => () => {},
}));
let backend: BackendState;
vi.mock('../src/renderer/useBackend', () => ({
  isPreview: false,
  api,
  useBackend: () => backend,
}));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

const heading = (name: string) => screen.getByRole('heading', { name, level: 2 });
const startButton = () => screen.getByRole('button', { name: /Start serving with Autopilot/ });
const autopilot = { action: 'autopilot', models: ['gpt-oss-20b'], pinned: [], endpoint: true };

function toStartPage(state = snapshot(), done = vi.fn()) {
  backend = backendWith(state);
  const view = render(<Onboarding backend={backend} done={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  expect(heading('Ready to serve.')).toBeVisible();
  const update = (next: Snapshot) => {
    backend = { ...backend, state: next };
    view.rerender(<Onboarding backend={backend} done={done} />);
  };
  return { done, update };
}

it('opens on the welcome view and checks this Mac once the runtime connects', async () => {
  localStorage.clear();
  backend = backendWith(undefined, { status: { state: 'missing' } });
  const { rerender } = render(<App />);
  expect(heading('Put this Mac to work.')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  expect(heading('Install Darkbloom to check this Mac.')).toBeVisible();
  backend = { ...backend, status: { state: 'ready' }, state: await previewAPI.read('state') };
  rerender(<App />);
  expect(heading('Checking this Mac…')).toBeVisible();
  expect(screen.queryByRole('heading', { name: 'Your contribution' })).not.toBeInTheDocument();
});

it('states what Autopilot will do from reported facts, with the terms beside the action', () => {
  toStartPage(snapshot({ eligibility: undefined }));
  const summary = screen.getByRole('region', { name: 'What happens next' });
  expect(summary).toHaveTextContent('MacBook Pro');
  expect(summary).toHaveTextContent('Apple M4 Max · 64 GB');
  expect(summary).toHaveTextContent('Starts with GPT-OSS 20B, already on this Mac.');
  expect(summary).toHaveTextContent('Updates on · managed by the native runtime.');
  expect(summary).toHaveTextContent('Stop any time from the app or the menu bar.');
  expect(screen.getByText('Your Darkbloom account is linked.')).toBeVisible();
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  expect(screen.getByText(/By turning on, you agree to our/)).toBeVisible();
  expect(screen.getByRole('button', { name: 'Advanced' })).toHaveAttribute(
    'aria-expanded',
    'false',
  );
});

it('starts with the smallest eligible download on a fresh install', () => {
  toStartPage(snapshot({ models: models.map((model) => ({ ...model, downloaded: false })) }));
  expect(screen.getByRole('region', { name: 'What happens next' })).toHaveTextContent(
    'Starts with Qwen 3.5 9B, downloading 6.1 GB first.',
  );
});

it('starts serving with Autopilot in one click', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  const { done } = toStartPage();
  fireEvent.click(startButton());
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(api.act).toHaveBeenCalledExactlyOnceWith(autopilot);
  expect(backend.act).not.toHaveBeenCalled();
  expect(backend.refresh).toHaveBeenCalled();
});

it('links an unlinked account first, then starts as soon as it is linked', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  const unlinked = snapshot({ linked: false });
  const { done, update } = toStartPage(unlinked);
  expect(
    screen.getByText(
      'First you’ll link your Darkbloom account in the browser, then serving starts.',
    ),
  ).toBeVisible();
  await act(async () => fireEvent.click(startButton()));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'link' });
  expect(screen.getByRole('region', { name: 'Link your account' })).toBeVisible();
  expect(screen.getByText('Getting a link code…')).toBeVisible();
  const link = { url: 'https://darkbloom.dev/link', code: 'KXQF-7M2P', expires_at: 0, state: '' };
  update({ ...unlinked, link });
  expect(screen.getByText('KXQF-7M2P')).toBeVisible();
  expect(screen.getByText('Waiting for approval…')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: /Open browser/ }));
  expect(api.openExternal).toHaveBeenCalledWith('link');
  expect(api.act).not.toHaveBeenCalled();
  update({ ...unlinked, linked: true });
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(api.act).toHaveBeenCalledExactlyOnceWith(autopilot);
});

it('recovers when linking fails or is cancelled', async () => {
  const unlinked = snapshot({ linked: false });
  const { update } = toStartPage(unlinked);
  await act(async () => fireEvent.click(startButton()));
  const failed = operation('failed', 'Expired', 'link');
  update({ ...unlinked, operations: [failed] });
  expect(screen.getByRole('alert')).toHaveTextContent(
    'Linking didn’t finish. Start again to get a new code.',
  );
  expect(startButton()).toBeEnabled();
  await act(async () => fireEvent.click(startButton()));
  const running = { ...operation('running', '', 'link'), id: 'second-link', cancellable: true };
  update({ ...unlinked, operations: [running, failed] });
  expect(screen.getByRole('region', { name: 'Link your account' })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(backend.act).toHaveBeenLastCalledWith({ action: 'cancel', operation: running.id });
  expect(startButton()).toBeVisible();
  expect(api.act).not.toHaveBeenCalled();
});

it('shows the runtime’s reason when Autopilot fails for another cause', async () => {
  api.act.mockResolvedValue(operation('failed', 'No verified models on this Mac.', 'autopilot'));
  const { done } = toStartPage();
  await act(async () => fireEvent.click(startButton()));
  expect(screen.getByRole('alert')).toHaveTextContent('No verified models on this Mac.');
  expect(screen.queryByText(/Autopilot isn’t available/)).not.toBeInTheDocument();
  expect(startButton()).toBeEnabled();
  expect(done).not.toHaveBeenCalled();
});

it('starts without overriding an automatic-update opt-out', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  const optedOut = snapshot();
  optedOut.settings = { ...optedOut.settings, auto_update: false };
  const { done } = toStartPage(optedOut);
  expect(screen.getByText('Updates off · turn them on any time in Updates.')).toBeVisible();
  fireEvent.click(startButton());
  await waitFor(() => expect(done).toHaveBeenCalled());
  expect(api.act).toHaveBeenCalledExactlyOnceWith(autopilot);
  expect(backend.act).not.toHaveBeenCalled();
});
