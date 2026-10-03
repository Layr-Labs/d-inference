// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Onboarding } from '../src/renderer/components/Onboarding';
import { scanTiming } from '../src/renderer/components/onboarding/scanScript';
import type { BackendState } from '../src/renderer/useBackend';
import { backendWith, eightGBMac, models, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  install: vi.fn(),
  act: vi.fn(),
  read: vi.fn(),
  openExternal: vi.fn(),
  onNavigate: () => () => {},
}));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));

const { revealMs, holdMs, exitMs, reducedHoldMs } = scanTiming;
const heading = (name: string) => screen.queryByRole('heading', { name, level: 2 });
const elapse = (ms: number) => act(() => vi.advanceTimersByTime(ms));
const currentStep = () =>
  screen.getByRole('list', { name: 'Setup steps' }).querySelector('[aria-current="step"]');
const renderOnboarding = (backend: BackendState, done = vi.fn()) => {
  const view = render(<Onboarding backend={backend} done={done} />);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  return view;
};

beforeEach(() => vi.useFakeTimers());
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.clearAllMocks();
  Reflect.deleteProperty(window, 'matchMedia');
});

describe('welcome', () => {
  it('waits for Start before checking, and judges the snapshot seen at that moment', () => {
    const backend = backendWith(eightGBMac());
    const { rerender } = render(<Onboarding backend={backend} done={vi.fn()} />);
    expect(heading('Put this Mac to work.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    expect(screen.getAllByRole('button')).toHaveLength(2);
    elapse(30_000);
    expect(heading('Put this Mac to work.')).toBeVisible();
    rerender(<Onboarding backend={{ ...backend, state: snapshot() }} done={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    expect(heading('Checking this Mac…')).toBeVisible();
    elapse(revealMs);
    expect(heading('This Mac is eligible.')).toBeVisible();
  });
});

describe('eligible Mac', () => {
  it('reveals this Mac, confirms it, and moves to the start page about five seconds later', () => {
    renderOnboarding(backendWith(snapshot()));
    expect(heading('Checking this Mac…')).toBeVisible();
    const card = screen.getByRole('region', { name: 'This Mac' });
    expect(within(card).getByText('MacBook Pro')).toBeVisible();
    expect(within(card).getByText('Apple M4 Max')).toBeVisible();
    expect(within(card).queryByText('64 GB')).not.toBeInTheDocument();
    elapse(revealMs - 1);
    expect(within(card).getByText('64 GB')).toBeVisible();
    expect(within(card).getAllByRole('img', { name: 'Met' })).toHaveLength(2);
    expect(heading('Checking this Mac…')).toBeVisible();
    elapse(1);
    expect(heading('This Mac is eligible.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Check this Mac');
    elapse(holdMs + exitMs - 1);
    expect(heading('This Mac is eligible.')).toBeVisible();
    elapse(1);
    expect(heading('Ready to serve.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Start');
  });

  it('skips ahead on request, and the finished scan never pulls the step back', () => {
    renderOnboarding(backendWith(snapshot()));
    elapse(500);
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(heading('Ready to serve.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Start');
    elapse(10_000);
    expect(heading('Ready to serve.')).toBeVisible();
    expect(currentStep()).toHaveTextContent('Start');
  });

  it('can continue straight from the verdict', () => {
    renderOnboarding(backendWith(snapshot()));
    elapse(revealMs);
    fireEvent.click(screen.getByRole('button', { name: /Continue now/ }));
    expect(heading('Ready to serve.')).toBeVisible();
  });

  it('shows the whole result at once under reduced motion and still moves on', () => {
    window.matchMedia = vi.fn((query: string) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })) as unknown as typeof window.matchMedia;
    renderOnboarding(backendWith(snapshot()));
    expect(heading('This Mac is eligible.')).toBeVisible();
    expect(screen.getByText('64 GB')).toBeVisible();
    elapse(reducedHoldMs - 1);
    expect(heading('This Mac is eligible.')).toBeVisible();
    elapse(1);
    expect(heading('Ready to serve.')).toBeVisible();
  });
});

describe('ineligible Mac', () => {
  it('names the reason, offers the waitlist, and never advances on its own', () => {
    const done = vi.fn();
    renderOnboarding(backendWith(eightGBMac()), done);
    elapse(revealMs);
    expect(heading('This Mac isn’t eligible yet.')).toBeVisible();
    expect(
      screen.getByText(
        'This Mac has 8 GB of unified memory; the smallest supported model needs 16.4 GB.',
      ),
    ).toBeVisible();
    expect(screen.getByRole('img', { name: 'Not met' })).toBeVisible();
    expect(screen.getByRole('textbox', { name: 'Email address' })).toBeVisible();
    elapse(60_000);
    expect(heading('This Mac isn’t eligible yet.')).toBeVisible();
    expect(heading('Ready to serve.')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Open dashboard/ }));
    expect(done).toHaveBeenCalledOnce();
  });

  it('shows the verdict at once when the scan is skipped', () => {
    renderOnboarding(backendWith(eightGBMac()));
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(heading('This Mac isn’t eligible yet.')).toBeVisible();
  });

  it('explains the runtime’s own failed checks', () => {
    renderOnboarding(
      backendWith(
        snapshot({
          eligibility: {
            eligible: false,
            checked_at: 1,
            checks: [
              { id: 'apple_silicon', label: 'Apple silicon', ok: true, value: 'Apple M4 Max' },
              {
                id: 'security',
                label: 'Security',
                ok: false,
                value: 'SIP off',
                detail: 'Turn System Integrity Protection back on, then check again.',
              },
            ],
          },
        }),
      ),
    );
    elapse(revealMs);
    expect(heading('This Mac isn’t eligible yet.')).toBeVisible();
    expect(
      screen.getByText('Turn System Integrity Protection back on, then check again.'),
    ).toBeVisible();
    expect(screen.queryByText('Unified memory')).not.toBeInTheDocument();
  });
});

describe('when the result is not known yet', () => {
  it('keeps scanning until the runtime delivers a snapshot', () => {
    const connecting = backendWith(undefined, {
      status: { state: 'connecting', message: 'Reconnecting to the runtime…' },
    });
    const { rerender } = renderOnboarding(connecting);
    elapse(30_000);
    expect(heading('Checking this Mac…')).toBeVisible();
    expect(screen.getByText('Reconnecting to the runtime…')).toBeVisible();
    expect(screen.queryByRole('button', { name: /Skip/ })).not.toBeInTheDocument();
    rerender(<Onboarding backend={backendWith(snapshot())} done={vi.fn()} />);
    expect(heading('Checking this Mac…')).toBeVisible();
    elapse(revealMs);
    expect(heading('This Mac is eligible.')).toBeVisible();
  });

  it('says it is installing while the runtime installs', () => {
    renderOnboarding(
      backendWith(undefined, {
        status: { state: 'installing', message: 'Installing the verified Swift runtime…' },
      }),
    );
    expect(heading('Installing Darkbloom…')).toBeVisible();
    expect(screen.getByText('Installing the verified Swift runtime…')).toBeVisible();
  });

  it('lets people check again or continue when a requirement can’t be evaluated', async () => {
    const backend = backendWith(snapshot({ models: models.map(({ memory_gb: _, ...m }) => m) }));
    renderOnboarding(backend);
    elapse(revealMs);
    expect(heading('We couldn’t confirm everything.')).toBeVisible();
    expect(
      screen.getByText('The runtime didn’t report how much memory its models need.'),
    ).toBeVisible();
    expect(screen.getByRole('img', { name: 'Couldn’t check' })).toBeVisible();
    elapse(60_000);
    expect(heading('We couldn’t confirm everything.')).toBeVisible();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Check again/ })));
    expect(backend.refresh).toHaveBeenCalledOnce();
    expect(heading('Checking this Mac…')).toBeVisible();
    elapse(revealMs);
    expect(heading('We couldn’t confirm everything.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: /Continue setup/ }));
    expect(heading('Ready to serve.')).toBeVisible();
  });

  it('rescans from a fresh snapshot rather than the one it already judged', async () => {
    let resolveRefresh = () => {};
    const backend = backendWith(eightGBMac(), {
      refresh: vi.fn(() => new Promise<void>((resolve) => (resolveRefresh = resolve))),
    });
    const { rerender } = renderOnboarding(backend);
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Check again/ })));
    elapse(revealMs);
    expect(heading('Checking this Mac…')).toBeVisible();
    rerender(<Onboarding backend={{ ...backend, state: snapshot() }} done={vi.fn()} />);
    await act(async () => resolveRefresh());
    elapse(revealMs);
    expect(heading('This Mac is eligible.')).toBeVisible();
  });
});

describe('runtime setup', () => {
  it('installs the runtime before it can check this Mac', () => {
    api.install.mockResolvedValue(undefined);
    renderOnboarding(
      backendWith(undefined, {
        status: { state: 'missing', message: 'Install the Darkbloom runtime to connect this Mac.' },
      }),
    );
    expect(heading('Install Darkbloom to check this Mac.')).toBeVisible();
    fireEvent.click(screen.getByRole('button', { name: /Install runtime/ }));
    expect(api.install).toHaveBeenCalledOnce();
  });

  it('offers a repair when the runtime is unreachable', async () => {
    api.install.mockRejectedValue(new Error('Runtime installation failed'));
    renderOnboarding(
      backendWith(undefined, {
        status: {
          state: 'error',
          message: 'Could not connect to the runtime. Update or repair the installation.',
        },
      }),
    );
    expect(heading('We couldn’t check this Mac.')).toBeVisible();
    await act(async () => fireEvent.click(screen.getByRole('button', { name: /Repair runtime/ })));
    expect(screen.getByRole('alert')).toHaveTextContent('Runtime installation failed');
  });
});
