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

it('shows the CLI install screen and installs nothing until the click', () => {
  api.install.mockResolvedValue(undefined);
  setup({ state: 'missing', message: 'Install the Darkbloom CLI to connect this Mac.' });
  expect(screen.getByRole('heading', { name: 'Install the Darkbloom CLI' })).toBeVisible();
  expect(
    screen.getByText(
      'Darkbloom runs on its command-line tool. It installs once, runs a background service that serves models on this Mac, and updates automatically.',
    ),
  ).toBeVisible();
  expect(api.install).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: /Install CLI/ }));
  expect(api.install).toHaveBeenCalledOnce();
});

it.each([
  ['error', 'Repair CLI'],
  ['incompatible', 'Update CLI'],
] as const)('offers %s as %s', (state, label) => {
  setup({ state });
  expect(screen.getByRole('button', { name: new RegExp(label) })).toBeEnabled();
  expect(api.install).not.toHaveBeenCalled();
});

it('shows install progress with a way out, never a second install', () => {
  setup({ state: 'installing', message: 'Downloading the CLI… 42%' });
  expect(screen.getByRole('heading', { name: 'Install the Darkbloom CLI' })).toBeVisible();
  expect(screen.getByRole('status')).toHaveTextContent('Downloading the CLI… 42%');
  expect(
    screen.queryByRole('button', { name: /Install|Repair|Update|Retry/ }),
  ).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: /Cancel/ }));
  expect(api.cancelInstall).toHaveBeenCalledOnce();
  expect(api.install).not.toHaveBeenCalled();
});

it('keeps why an install stopped next to Retry', () => {
  api.install.mockResolvedValue(undefined);
  const message =
    'Couldn’t install the CLI while finding the latest release: Could not reach coordinator at https://api.darkbloom.dev.';
  setup({ state: 'missing', message, installFailed: true });
  expect(screen.getByRole('heading', { name: 'Install the Darkbloom CLI' })).toBeVisible();
  expect(screen.getAllByRole('status')).toHaveLength(1);
  expect(screen.getByRole('status')).toHaveTextContent(message);
  expect(screen.queryByRole('button', { name: /Install CLI/ })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: /Get help/ })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: /Retry/ }));
  expect(api.install).toHaveBeenCalledOnce();
});

it('keeps the first-run install wording after a cancelled install', () => {
  setup({ state: 'missing', message: 'CLI install cancelled.' });
  expect(screen.getByRole('heading', { name: 'Install the Darkbloom CLI' })).toBeVisible();
  expect(screen.getByRole('status')).toHaveTextContent('CLI install cancelled.');
  expect(screen.getByRole('button', { name: /Install CLI/ })).toBeEnabled();
  expect(screen.queryByRole('button', { name: /Get help/ })).not.toBeInTheDocument();
  expect(api.install).not.toHaveBeenCalled();
});

it('offers a returning user Retry after a failed reinstall, with their own wording', () => {
  render(
    <RuntimeSetup
      backend={backendWith(undefined, {
        status: { state: 'missing', message: 'Download failed.', installFailed: true },
      })}
      returningUser
    />,
  );
  expect(
    screen.getByRole('heading', { name: 'Reinstall the Darkbloom CLI to continue.' }),
  ).toBeVisible();
  expect(screen.getByRole('status')).toHaveTextContent('Download failed.');
  expect(screen.getByRole('button', { name: /Retry/ })).toBeEnabled();
  expect(screen.queryByRole('button', { name: /Install CLI/ })).not.toBeInTheDocument();
});
