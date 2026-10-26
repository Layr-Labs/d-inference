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
  openSoftwareUpdate: vi.fn().mockResolvedValue(undefined),
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
function renderWith(status: DesktopStatus, state?: Snapshot, macosVersion = '27.0') {
  let backend: BackendState = backendWith(state, { status, system: { macosVersion } });
  const done = vi.fn();
  const view = render(<Onboarding backend={backend} done={done} />);
  const update = (next: DesktopStatus, nextState: Snapshot | undefined = backend.state) => {
    backend = { ...backend, status: next, state: nextState };
    view.rerender(<Onboarding backend={backend} done={done} />);
  };
  return { done, update };
}

describe('install step', () => {
  it('puts installing the Darkbloom CLI first, before the check, linking and the start', () => {
    renderWith({ state: 'ready' }, snapshot({ linked: false }));
    // A done step shows a check in place of its number.
    expect(stepItems().map((step) => step.textContent)).toEqual([
      'Install CLI',
      '2Check this Mac',
      '3Link your account',
      '4Start',
    ]);
    expect(stepItems()[0]).toHaveClass('complete');
    expect(currentStep()).toHaveTextContent('Check this Mac');
    expect(heading('Put this Mac to work.')).toBeVisible();
  });

  it('starts there when the CLI is missing, and nothing later is reachable', () => {
    api.install.mockResolvedValue(undefined);
    renderWith({ state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(
      screen.getByText(
        'Darkbloom runs on its command-line tool. It installs once, runs a background service that serves models on this Mac, and updates automatically.',
      ),
    ).toBeVisible();
    expect(currentStep()).toHaveTextContent('Install CLI');
    expect(screen.getByRole('status')).toHaveTextContent(
      'Install the Darkbloom CLI to connect this Mac.',
    );
    expect(button(/Link account/)).toBeNull();
    expect(button('Start')).toBeNull();
    expect(button(/Explore the app first/)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /Install CLI/ }));
    expect(api.install).toHaveBeenCalledOnce();
  });

  it('never starts an install without a click', () => {
    const { update } = renderWith({ state: 'connecting' });
    update({ state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' });
    update({ state: 'error', message: 'Could not connect to the Darkbloom CLI.' });
    update({ state: 'incompatible' });
    update({ state: 'missing' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('button', { name: /Install CLI/ })).toBeEnabled();
    expect(api.install).not.toHaveBeenCalled();
  });

  it('shows the progress the main process reports while installing, with no second Install', () => {
    const { update } = renderWith({ state: 'installing', message: 'Downloading the CLI… 42%' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('Downloading the CLI… 42%');
    expect(button(/CLI/)).toBeNull();
    update({ state: 'installing', message: 'Verifying the CLI’s signature…' });
    expect(screen.getByRole('status')).toHaveTextContent('Verifying the CLI’s signature…');
    expect(button(/CLI/)).toBeNull();
    update({ state: 'installing' });
    expect(screen.getByRole('status')).toHaveTextContent('Installing the Darkbloom CLI…');
    expect(button(/Explore the app first/)).toBeNull();
  });

  it('moves on to the check once installed, with the install step done and focus on it', () => {
    const { update } = renderWith({ state: 'installing', message: 'Installing…' });
    update({ state: 'connecting' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    update({ state: 'ready' }, snapshot({ linked: false }));
    expect(heading('Checking this Mac…')).toBeVisible();
    expect(heading('Checking this Mac…')).toHaveFocus();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    expect(stepItems()[0]).toHaveClass('complete');
    expect(button(/Link account/)).toBeNull();
    // An eligible, unlinked Mac then links its account.
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(heading('Link your account.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Link your account');
    expect(stepItems()[1]).toHaveClass('complete');
    expect(screen.getByRole('button', { name: /Link account/ })).toBeEnabled();
  });

  it('goes from the check to Start after installing on a Mac that is already linked', () => {
    const { update } = renderWith({ state: 'missing' });
    update({ state: 'installing' });
    update({ state: 'ready' }, snapshot());
    expect(heading('Checking this Mac…')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(heading('Ready to serve.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Start');
    expect(
      stepItems()
        .slice(0, 3)
        .every((step) => step.classList.contains('complete')),
    ).toBe(true);
  });

  it('opens on the welcome view at the check, linked or not, if already installed', () => {
    const { update } = renderWith({ state: 'connecting' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('status')).toHaveTextContent('Connecting to the Darkbloom CLI…');
    expect(button(/CLI/)).toBeNull();
    update({ state: 'ready' }, snapshot({ linked: false }));
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    expect(stepItems()[0]).toHaveClass('complete');
    cleanup();
    renderWith({ state: 'ready' }, snapshot());
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
  });

  it('gives the reason and a repair when the CLI failed, and the error of a failed retry', async () => {
    api.install.mockRejectedValue(new Error('Runtime installation failed'));
    renderWith({
      state: 'error',
      message: 'Installation failed. Check your connection and retry.',
    });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(api.install).not.toHaveBeenCalled();
    expect(screen.getByRole('status')).toHaveTextContent(
      'Installation failed. Check your connection and retry.',
    );
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Repair CLI/ })));
    expect(api.install).toHaveBeenCalledOnce();
    expect(screen.getByRole('alert')).toHaveTextContent('Runtime installation failed');
    expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeEnabled();
  });

  it('offers an update when the CLI is incompatible', () => {
    renderWith({ state: 'incompatible', message: 'This CLI is too old for the app.' });
    expect(screen.getByRole('status')).toHaveTextContent('This CLI is too old for the app.');
    expect(screen.getByRole('button', { name: /Update CLI/ })).toBeVisible();
  });

  it('keeps the current step through a reconnect, and returns to it after a repair', () => {
    const { update } = renderWith({ state: 'ready' }, snapshot({ linked: false }));
    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(heading('Link your account.')).toBeVisible();
    update({ state: 'connecting', message: 'Reconnecting to the Darkbloom CLI…' });
    expect(heading('Link your account.')).toBeVisible();
    update({ state: 'error', message: 'Could not connect to the Darkbloom CLI.' });
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Install CLI');
    expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeVisible();
    update({ state: 'ready' });
    expect(heading('Link your account.')).toBeVisible();
    expect(heading('Link your account.')).toHaveFocus();
  });
});

describe('macOS below 27', () => {
  it('asks a new Mac to update macOS instead of installing the CLI', () => {
    const { update } = renderWith(
      { state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' },
      undefined,
      '26.5',
    );
    expect(heading('Install the Darkbloom CLI')).toBeNull();
    expect(heading('Darkbloom needs macOS 27 or later')).toBeVisible();
    expect(
      screen.getByText(
        'New Macs can join Darkbloom on macOS 27 or later. This Mac runs macOS 26.5. Update macOS, then reopen Darkbloom.',
      ),
    ).toBeVisible();
    expect(currentStep()).toHaveTextContent('Install CLI');
    expect(button(/Install CLI/)).toBeNull();
    expect(button(/Link account/)).toBeNull();
    expect(button(/Explore the app first/)).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: /Open Software Update/ }));
    expect(api.openSoftwareUpdate).toHaveBeenCalledOnce();
    expect(api.install).not.toHaveBeenCalled();
    // Still blocked when the main process reports the CLI missing again.
    update({ state: 'missing' });
    expect(heading('Darkbloom needs macOS 27 or later')).toBeVisible();
    expect(button(/Install CLI/)).toBeNull();
  });

  it('offers the install as usual on macOS 27 or later, or when the version is unknown', () => {
    for (const version of ['27.0', '28.1', '']) {
      renderWith({ state: 'missing' }, undefined, version);
      expect(heading('Install the Darkbloom CLI')).toBeVisible();
      expect(screen.getByRole('button', { name: /Install CLI/ })).toBeEnabled();
      expect(button(/Open Software Update/)).toBeNull();
      cleanup();
    }
  });

  it('lets a Mac that already has the CLI carry on: connected, broken or outdated', () => {
    renderWith({ state: 'ready' }, snapshot({ linked: false }), '26.5');
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    cleanup();
    renderWith(
      { state: 'error', message: 'Could not connect to the Darkbloom CLI.' },
      undefined,
      '26.5',
    );
    expect(heading('Install the Darkbloom CLI')).toBeVisible();
    expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeEnabled();
    cleanup();
    renderWith({ state: 'incompatible' }, undefined, '26.5');
    expect(screen.getByRole('button', { name: /Update CLI/ })).toBeEnabled();
    expect(button(/Open Software Update/)).toBeNull();
  });
});
