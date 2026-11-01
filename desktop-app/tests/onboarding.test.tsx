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
  install: vi.fn(),
  act: vi.fn(),
  read: vi.fn(),
  openExternal: vi.fn(),
  onNavigate: () => () => {},
  onHardware: () => () => {},
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

it('opens on Install the Darkbloom CLI and checks this Mac once it connects', async () => {
  localStorage.clear();
  backend = backendWith(undefined, { status: { state: 'missing' } });
  const { rerender } = render(<App />);
  expect(heading('Install the Darkbloom CLI')).toBeVisible();
  expect(screen.getByRole('button', { name: /Install CLI/ })).toBeVisible();
  expect(api.install).not.toHaveBeenCalled();
  expect(screen.queryByRole('button', { name: 'Start' })).not.toBeInTheDocument();
  backend = { ...backend, status: { state: 'ready' }, state: await previewAPI.read('state') };
  rerender(<App />);
  expect(heading('Checking this Mac…')).toBeVisible();
  expect(screen.queryByRole('heading', { name: 'Your contribution' })).not.toBeInTheDocument();
});

it('leaves setup for the app mid-check, and stays there once the check would have ended', () => {
  vi.useFakeTimers();
  try {
    localStorage.clear();
    api.read.mockReturnValue(new Promise(() => {}));
    backend = backendWith(snapshot());
    render(<App />);
    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    expect(heading('Checking this Mac…')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: /Explore the app first/ }));
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeVisible();
    expect(localStorage.getItem('darkbloom.onboardingComplete')).toBe('1');
    act(() => vi.advanceTimersByTime(60_000));
    expect(screen.queryByRole('heading', { name: 'Ready to serve.' })).not.toBeInTheDocument();
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeVisible();
  } finally {
    vi.useRealTimers();
  }
});

it('states what Autopilot will do from reported facts, with the terms beside the action', () => {
  toStartPage(snapshot({ eligibility: undefined }));
  const summary = screen.getByRole('region', { name: 'What happens next' });
  expect(summary).toHaveTextContent('MacBook Pro');
  expect(summary).toHaveTextContent('Apple M4 Max · 64 GB');
  expect(summary).toHaveTextContent('Starts with GPT-OSS 20B, already on this Mac.');
  expect(summary).toHaveTextContent('Automatic updates on.');
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

const steps = () => screen.getByRole('list', { name: 'Setup steps' });
const currentStep = () => steps().querySelector('[aria-current="step"]');

function renderUnlinked(state = snapshot({ linked: false })) {
  backend = backendWith(state);
  const done = vi.fn();
  const view = render(<Onboarding backend={backend} done={done} />);
  const update = (next: Snapshot) => {
    backend = { ...backend, state: next };
    view.rerender(<Onboarding backend={backend} done={done} />);
  };
  return { done, update };
}

it('checks this Mac first, then links the account, opening the browser only from its button', async () => {
  api.act.mockResolvedValue(operation('succeeded', '', 'autopilot'));
  const unlinked = snapshot({ linked: false });
  const { done, update } = renderUnlinked(unlinked);
  expect([...steps().querySelectorAll('li')].map((step) => step.textContent)).toEqual([
    'Install CLI',
    '2Check this Mac',
    '3Link your account',
    '4Start',
  ]);
  expect(currentStep()).toHaveTextContent('Check this Mac');
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  expect(heading('Checking this Mac…')).toBeVisible();
  expect(screen.queryByRole('button', { name: /Link account/ })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  expect(heading('Link your account.')).toBeVisible();
  expect(currentStep()).toHaveTextContent('Link your account');
  expect(steps().querySelectorAll('li.complete')).toHaveLength(2);
  expect(screen.getByText(/Earnings from this Mac go to your Darkbloom account/)).toBeVisible();
  expect(backend.act).not.toHaveBeenCalled();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Link account/ })));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'link' });
  expect(screen.getByRole('region', { name: 'Link your account' })).toBeVisible();
  expect(screen.getByText('Getting a link code…')).toBeVisible();
  const link = { url: 'https://darkbloom.dev/link', code: 'KXQF-7M2P', expires_at: 0, state: '' };
  update({ ...unlinked, link });
  expect(screen.getByText('KXQF-7M2P')).toBeVisible();
  expect(screen.getByText('Waiting for approval…')).toBeVisible();
  expect(api.openExternal).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: /Open link page/ }));
  expect(api.openExternal).toHaveBeenCalledExactlyOnceWith('link');
  expect(api.act).not.toHaveBeenCalled();
  update({ ...unlinked, linked: true });
  expect(heading('Ready to serve.')).toBeVisible();
  expect(currentStep()).toHaveTextContent('Start');
  expect(steps().querySelectorAll('li.complete')).toHaveLength(3);
  expect(screen.getByText('Your Darkbloom account is linked.')).toBeVisible();
  fireEvent.click(startButton());
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(api.act).toHaveBeenCalledExactlyOnceWith(autopilot);
  expect(backend.act).toHaveBeenCalledOnce();
});

it('skips linking on a Mac that is already linked, going from the check to Start', () => {
  backend = backendWith(snapshot());
  render(<Onboarding backend={backend} done={vi.fn()} />);
  expect(currentStep()).toHaveTextContent('Check this Mac');
  expect(steps().querySelectorAll('li.complete')).toHaveLength(1);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  expect(heading('Checking this Mac…')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  expect(heading('Ready to serve.')).toBeVisible();
  expect(currentStep()).toHaveTextContent('Start');
  // Install, the check and linking are all done; linking was never shown.
  expect([...steps().querySelectorAll('li.complete')].map((step) => step.textContent)).toEqual([
    'Install CLI',
    'Check this Mac',
    'Link your account',
  ]);
  expect(screen.queryByRole('button', { name: /Link account/ })).not.toBeInTheDocument();
  expect(backend.act).not.toHaveBeenCalled();
});

it('recovers when linking fails or is cancelled', async () => {
  const unlinked = snapshot({ linked: false });
  const { update } = renderUnlinked(unlinked);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  const linkButton = () => screen.getByRole('button', { name: /Link account/ });
  await act(async () => fireEvent.click(linkButton()));
  const failed = operation('failed', 'Expired', 'link');
  update({ ...unlinked, operations: [failed] });
  expect(screen.getByRole('alert')).toHaveTextContent(
    'Linking didn’t finish. Link again to get a new code.',
  );
  expect(linkButton()).toBeEnabled();
  await act(async () => fireEvent.click(linkButton()));
  const running = { ...operation('running', '', 'link'), id: 'second-link', cancellable: true };
  update({ ...unlinked, operations: [running, failed] });
  expect(screen.getByRole('region', { name: 'Link your account' })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(backend.act).toHaveBeenLastCalledWith({ action: 'cancel', operation: running.id });
  expect(linkButton()).toBeVisible();
  expect(api.act).not.toHaveBeenCalled();
});

it('sends a start back to link the account if it is no longer linked', async () => {
  const { update } = toStartPage();
  const unlinked = snapshot({ linked: false });
  update(unlinked);
  expect(screen.getByText('Link your Darkbloom account first. Serving needs it.')).toBeVisible();
  fireEvent.click(startButton());
  expect(heading('Link your account.')).toBeVisible();
  expect(currentStep()).toHaveTextContent('Link your account');
  expect(backend.act).not.toHaveBeenCalled();
  expect(api.act).not.toHaveBeenCalled();
  expect(api.openExternal).not.toHaveBeenCalled();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Link account/ })));
  update({ ...unlinked, linked: true });
  expect(heading('Ready to serve.')).toBeVisible();
  expect(startButton()).toBeEnabled();
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
