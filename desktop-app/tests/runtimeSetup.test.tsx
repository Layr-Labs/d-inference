// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { RuntimeSetup } from '../src/renderer/components/onboarding/RuntimeSetup';
import type { DesktopStatus } from '../src/shared/contracts';
import { backendWith } from './onboardingFixtures';

const api = vi.hoisted(() => ({ install: vi.fn(), cancelInstall: vi.fn() }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));

const setup = (status: DesktopStatus) =>
  render(<RuntimeSetup backend={backendWith(undefined, { status })} />);
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it('shows install progress with a way out, never a second install', () => {
  setup({ state: 'installing', message: 'Downloading the backend… 42%' });
  expect(screen.getByRole('heading', { name: 'Installing the backend…' })).toBeVisible();
  expect(screen.getByRole('status')).toHaveTextContent('Downloading the backend… 42%');
  expect(screen.queryByRole('button', { name: /Install|Repair|Retry/ })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Cancel/ }));
  expect(api.cancelInstall).toHaveBeenCalledOnce();
  expect(api.install).not.toHaveBeenCalled();
});

it('keeps why an install stopped next to Retry', () => {
  api.install.mockResolvedValue(undefined);
  const message =
    'Couldn’t install the backend while finding the latest release: Could not reach coordinator at https://api.darkbloom.dev.';
  setup({ state: 'missing', message, installFailed: true });
  expect(screen.getByRole('heading', { name: 'The backend isn’t installed yet.' })).toBeVisible();
  expect(screen.getByRole('alert')).toHaveTextContent(message);
  expect(screen.queryByRole('button', { name: /Install runtime/ })).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Retry/ }));
  expect(api.install).toHaveBeenCalledOnce();
});

it('keeps the first-run install wording after a cancelled install', () => {
  setup({ state: 'missing', message: 'Backend installation cancelled.' });
  expect(
    screen.getByRole('heading', { name: 'Install Darkbloom to check this Mac.' }),
  ).toBeVisible();
  expect(screen.getByText('Backend installation cancelled.')).toBeVisible();
  expect(screen.getByRole('button', { name: /Install runtime/ })).toBeEnabled();
});
