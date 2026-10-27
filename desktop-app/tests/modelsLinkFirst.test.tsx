// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { NetworkData, Operation, Snapshot } from '../src/shared/contracts';
import { Models } from '../src/renderer/features/models/Models';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);

const network: NetworkData = {
  model_earnings: {
    window: '7d',
    as_of: new Date().toISOString(),
    models: [
      { id: 'qwen-3.6-35b', earnings_micro_usd: '4000000' },
      { id: 'qwen-3.5-9b', earnings_micro_usd: '3000000' },
    ],
  },
};
// First use on Models, and the manual page's offer, on a Mac that isn't linked yet.
const setup = (overrides: Partial<Snapshot> = {}) =>
  poolSnapshot(
    { enabled: false, configured: false, selected: [], pinned: [], phase: undefined },
    { linked: false, ...overrides },
  );
const manual = (overrides: Partial<Snapshot> = {}) =>
  poolSnapshot({ enabled: false, phase: 'off' }, { linked: false, ...overrides });
const explanation =
  /Autopilot needs this Mac linked to your Darkbloom account\. You’ll get a code here and open the link page in your browser to approve it\. Once you approve, Autopilot starts/;
const linking: Operation = {
  id: 'link-1',
  action: 'link',
  state: 'running',
  started_at: 1_790_000_000,
  message: '',
  cancellable: true,
};
const link = { url: 'https://darkbloom.dev/link', code: 'KXQF-7M2P', expires_at: 0, state: '' };

it('says before the click that starting Autopilot links this Mac in the browser first', () => {
  render(<Models backend={backendWith(setup(), { network })} />);
  expect(screen.getByText(explanation)).toBeVisible();
  expect(screen.getByRole('button', { name: 'Link this Mac & start Autopilot' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Link this Mac & turn on Autopilot' })).toBeEnabled();
  expect(screen.queryByRole('button', { name: /^Download & start/ })).not.toBeInTheDocument();
  cleanup();
  render(<Models backend={backendWith(manual())} />);
  expect(screen.getByRole('region', { name: 'Autopilot' })).toHaveTextContent(explanation);
  expect(screen.getByRole('button', { name: 'Link this Mac & turn on Autopilot' })).toBeEnabled();
});

it('keeps the plain labels once this Mac is linked', () => {
  render(<Models backend={backendWith(setup({ linked: true }), { network })} />);
  expect(screen.queryByText(explanation)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Download & start Autopilot' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Turn on Autopilot' })).toBeVisible();
});

it.each([
  ['first use', setup],
  ['the manual page', manual],
])('shows the code from %s with a Cancel button that stops the link', (_, state) => {
  const backend = backendWith(state({ link, operations: [linking] }));
  render(<Models backend={backend} />);
  const dialog = screen.getByRole('dialog', { name: 'Link this Mac' });
  expect(within(dialog).getByText('KXQF-7M2P')).toBeVisible();
  expect(dialog).toHaveTextContent('Open the link page and enter this code.');
  const cancel = within(dialog).getByRole('button', { name: 'Cancel' });
  expect(cancel).toHaveClass('button', 'secondary');
  fireEvent.click(cancel);
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'cancel', operation: 'link-1' });
});
