// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { DesktopStatus, Snapshot } from '../src/shared/contracts';
import type { BackendState } from '../src/renderer/useBackend';
import { Onboarding } from '../src/renderer/components/Onboarding';
import { backendWith, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  install: vi.fn(),
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

const heading = (name: string) => screen.queryByRole('heading', { name, level: 2 });
const steps = () => screen.getByRole('list', { name: 'Setup steps' });
const stepItems = () => [...steps().querySelectorAll('li')];
const currentStep = () => steps().querySelector('[aria-current="step"]');
const button = (name: string | RegExp) => screen.queryByRole('button', { name });

// Renders onboarding against a backend that can move between statuses, as the main process
// reports them.
function renderWith(status: DesktopStatus, state?: Snapshot) {
  let backend: BackendState = backendWith(state, { status });
  const done = vi.fn();
  const view = render(<Onboarding backend={backend} done={done} />);
  const update = (next: DesktopStatus, nextState: Snapshot | undefined = backend.state) => {
    backend = { ...backend, status: next, state: nextState };
    view.rerender(<Onboarding backend={backend} done={done} />);
  };
  return { done, update };
}

describe('install step', () => {
  it('puts installing the backend first, before linking, the check and the start', () => {
    renderWith({ state: 'ready' }, snapshot({ linked: false }));
    // A done step shows a check in place of its number.
    expect(stepItems().map((step) => step.textContent)).toEqual([
      'Install backend',
      '2Link your account',
      '3Check this Mac',
      '4Start',
    ]);
    expect(stepItems()[0]).toHaveClass('complete');
    expect(currentStep()).toHaveTextContent('Link your account');
    expect(heading('Put this Mac to work.')).toBeVisible();
  });

  it('starts there when the backend is missing, and nothing later is reachable', () => {
    api.install.mockResolvedValue(undefined);
    renderWith({ state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(
      screen.getByText(/Darkbloom runs on its command-line tool. It installs once, runs a background service/),
    ).toBeVisible();
    expect(currentStep()).toHaveTextContent('Install backend');
    expect(screen.getByRole('status')).toHaveTextContent(
      'Install the Darkbloom runtime to connect this Mac.',
    );
    expect(button(/Link account/)).toBeNull();
    expect(button('Start')).toBeNull();
    expect(button(/Explore the app first/)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /Install CLI/ }));
    expect(api.install).toHaveBeenCalledOnce();
  });

  it('shows the progress the main process reports while installing, with no second Install', () => {
    const { update } = renderWith({ state: 'installing', message: 'Downloading the backend…' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('Downloading the backend…');
    expect(button(/CLI/)).toBeNull();
    update({ state: 'installing', message: 'Verifying the backend…' });
    expect(screen.getByRole('status')).toHaveTextContent('Verifying the backend…');
    expect(button(/CLI/)).toBeNull();
    expect(button(/Explore the app first/)).toBeNull();
  });

  it('moves on to linking once installed, with the install step done and focus on Link', () => {
    const { update } = renderWith({ state: 'installing', message: 'Installing…' });
    update({ state: 'connecting' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    update({ state: 'ready' }, snapshot({ linked: false }));
    expect(heading('Link your account.')).toBeVisible();
    expect(heading('Link your account.')).toHaveFocus();
    expect(currentStep()).toHaveTextContent('Link your account');
    expect(stepItems()[0]).toHaveClass('complete');
    expect(screen.getByRole('button', { name: /Link account/ })).toBeEnabled();
  });

  it('goes straight to the check after installing on a Mac that is already linked', () => {
    const { update } = renderWith({ state: 'missing' });
    update({ state: 'installing' });
    update({ state: 'ready' }, snapshot());
    expect(heading('Checking this Mac…')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    expect(stepItems()[0]).toHaveClass('complete');
    expect(stepItems()[1]).toHaveClass('complete');
  });

  it('opens on the welcome view at Link, or at Check when linked, if already installed', () => {
    const { update } = renderWith({ state: 'connecting' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('Connecting to the Darkbloom CLI…');
    expect(button(/CLI/)).toBeNull();
    update({ state: 'ready' }, snapshot({ linked: false }));
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Link your account');
    expect(stepItems()[0]).toHaveClass('complete');
    cleanup();
    renderWith({ state: 'ready' }, snapshot());
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
  });

  it('gives the reason and a retry when the backend failed, and the error of a failed retry', async () => {
    api.install.mockRejectedValue(new Error('Runtime installation failed'));
    renderWith({
      state: 'error',
      message: 'Installation failed. Check your connection and retry.',
    });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent(
      'Installation failed. Check your connection and retry.',
    );
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Repair CLI/ })));
    expect(api.install).toHaveBeenCalledOnce();
    expect(screen.getByRole('alert')).toHaveTextContent('Runtime installation failed');
    expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeEnabled();
  });

  it('offers an update when the backend is incompatible', () => {
    renderWith({ state: 'incompatible', message: 'This backend is too old for the app.' });
    expect(screen.getByRole('status')).toHaveTextContent('This backend is too old for the app.');
    expect(screen.getByRole('button', { name: /Update CLI/ })).toBeVisible();
  });

  it('keeps the current step through a reconnect, and returns to it after a repair', () => {
    const { update } = renderWith({ state: 'ready' }, snapshot({ linked: false }));
    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    expect(heading('Link your account.')).toBeVisible();
    update({ state: 'connecting', message: 'Reconnecting to the runtime…' });
    expect(heading('Link your account.')).toBeVisible();
    update({ state: 'error', message: 'Could not connect to the runtime.' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Install backend');
    expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeVisible();
    update({ state: 'ready' });
    expect(heading('Link your account.')).toBeVisible();
    expect(heading('Link your account.')).toHaveFocus();
  });
});
