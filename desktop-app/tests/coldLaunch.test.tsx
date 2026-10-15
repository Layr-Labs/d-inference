// @vitest-environment jsdom
import React from 'react';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { DesktopStatus, Snapshot } from '../src/shared/contracts';
import { snapshot } from './onboardingFixtures';

let pushState: (state: Snapshot) => void;
let pushStatus: (status: DesktopStatus) => void;

// A native API whose first snapshot has not arrived yet, as on every cold launch.
async function launch(status: DesktopStatus) {
  (window as any).darkbloom = {
    status: async () => status,
    onState: (callback: typeof pushState) => ((pushState = callback), () => {}),
    onStatus: (callback: typeof pushStatus) => ((pushStatus = callback), () => {}),
    onNavigate: () => () => {},
    onHardware: () => () => {},
    system: async () => ({ macosVersion: '27.0' }),
    openSoftwareUpdate: async () => {},
    read: () => new Promise(() => {}),
    act: vi.fn(),
    updateStatus: () => new Promise(() => {}),
  };
  const App = (await import('../src/renderer/App')).default;
  render(<App />);
  await act(async () => {});
}

beforeEach(() => {
  vi.resetModules();
  localStorage.clear();
});
afterEach(() => {
  cleanup();
  delete (window as any).darkbloom;
});

it('shows a returning user the connection status instead of first-run onboarding', async () => {
  localStorage.setItem('darkbloom.onboardingComplete', '1');
  await launch({ state: 'connecting' });
  expect(screen.getByRole('status')).toHaveTextContent('Connecting to this Mac…');
  expect(screen.queryByText('Put this Mac to work.')).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: /Start/ })).not.toBeInTheDocument();
  await act(async () => pushState(snapshot()));
  expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeVisible();
});

it('offers a returning user repair directly when the CLI is unreachable', async () => {
  localStorage.setItem('darkbloom.onboardingComplete', '1');
  await launch({ state: 'connecting' });
  await act(async () => pushStatus({ state: 'error', message: 'Could not connect.' }));
  expect(screen.getByRole('button', { name: /Repair CLI/ })).toBeVisible();
  expect(screen.queryByText('Put this Mac to work.')).not.toBeInTheDocument();
});

it.each([
  ['missing', 'Reinstall the Darkbloom CLI to continue.', /Install CLI/],
  ['error', 'Darkbloom couldn’t start.', /Repair CLI/],
  ['incompatible', 'Update the Darkbloom CLI to continue.', /Update CLI/],
] as const)(
  'tells a returning user why the CLI is unavailable (%s)',
  async (state, title, action) => {
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    await launch({ state });
    expect(screen.getByRole('heading', { name: title })).toBeVisible();
    expect(screen.getByRole('button', { name: action })).toBeVisible();
    // Not first-run wording: no check is running, and an incompatible CLI was reached.
    expect(screen.queryByText(/check this Mac|couldn’t reach/)).not.toBeInTheDocument();
  },
);

it('still starts first-run onboarding, at its install step, before the first snapshot', async () => {
  await launch({ state: 'connecting' });
  expect(screen.getByRole('heading', { name: 'Install the Darkbloom CLI' })).toBeVisible();
  expect(screen.getByRole('status')).toHaveTextContent('Connecting to the Darkbloom CLI…');
  expect(screen.getByRole('list', { name: 'Setup steps' })).toBeVisible();
  expect(screen.queryByText('Connecting to this Mac…')).not.toBeInTheDocument();
});
