// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { BackendState } from '../src/renderer/useBackend';
import App from '../src/renderer/App';
import { OperationFeed } from '../src/renderer/components/UI';
import { AccountSignInProgress } from '../src/renderer/components/account/AccountSignInProgress';
import { RuntimeSetup } from '../src/renderer/components/onboarding/RuntimeSetup';
import { backendWith, operation, snapshot } from './onboardingFixtures';

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
beforeEach(() => {
  localStorage.setItem('darkbloom.onboardingComplete', '1');
  api.read.mockReturnValue(new Promise(() => {}));
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  localStorage.clear();
});

const getHelp = (scope: HTMLElement) => within(scope).getByRole('button', { name: /Get help/ });

it('opens help from the sidebar: the guide, Slack, and community discussions', () => {
  backend = backendWith(snapshot());
  render(<App />);
  const sidebar = document.querySelector<HTMLElement>('.sidebar')!;
  fireEvent.click(within(sidebar).getByRole('button', { name: 'Help' }));
  const dialog = screen.getByRole('dialog', { name: 'Help' });
  for (const name of [/Read the guide/, /Ask in Slack/, /Community discussions/])
    fireEvent.click(within(dialog).getByRole('button', { name }));
  expect(api.openExternal.mock.calls).toEqual([['docs'], ['slack'], ['community']]);
  expect(dialog).toHaveTextContent('When you ask, mention Darkbloom 0.9.16.');
  fireEvent.click(within(dialog).getByRole('button', { name: 'Close dialog' }));
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
});

it('offers help when the runtime can’t be reached, not while it reconnects', () => {
  backend = backendWith(snapshot(), {
    status: { state: 'error', message: 'Could not connect to the runtime.' },
  });
  const { rerender } = render(<App />);
  const notice = screen.getByText('Could not connect to the runtime.');
  fireEvent.click(getHelp(notice));
  expect(api.openExternal).toHaveBeenCalledExactlyOnceWith('docs');
  backend = backendWith(snapshot(), { status: { state: 'connecting' } });
  rerender(<App />);
  expect(screen.getByText('Connecting to this Mac…')).toBeVisible();
  expect(
    within(screen.getByRole('main')).queryByRole('button', { name: /Get help/ }),
  ).not.toBeInTheDocument();
});

it('offers help on a failed operation, and not on one that is still running', () => {
  const failed = backendWith(
    snapshot({ operations: [operation('failed', 'Download failed.', 'download')] }),
  );
  const { rerender } = render(<OperationFeed backend={failed} />);
  fireEvent.click(getHelp(screen.getByRole('alert')));
  expect(api.openExternal).toHaveBeenCalledExactlyOnceWith('docs');
  rerender(<OperationFeed backend={backendWith(snapshot(), { error: 'The action failed' })} />);
  expect(getHelp(screen.getByRole('alert'))).toBeVisible();
  const running = { ...operation('running', 'Downloading…', 'download'), id: 'running' };
  rerender(<OperationFeed backend={backendWith(snapshot({ operations: [running] }))} />);
  expect(screen.getByRole('status')).toBeVisible();
  expect(screen.queryByRole('button', { name: /Get help/ })).not.toBeInTheDocument();
});

it('offers help beside Try again when sign-in fails', () => {
  const onRetry = vi.fn();
  render(
    <AccountSignInProgress
      backend={backendWith(snapshot())}
      operation={operation('failed', 'Expired', 'account-signin')}
      requestFailed={false}
      submitting={false}
      onRetry={onRetry}
      onClose={vi.fn()}
    />,
  );
  expect(screen.getByText('Could not complete sign-in.')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  expect(onRetry).toHaveBeenCalledOnce();
  fireEvent.click(screen.getByRole('button', { name: /Get help/ }));
  expect(api.openExternal).toHaveBeenCalledExactlyOnceWith('docs');
});

it('offers help when installing or repairing the CLI fails', async () => {
  api.install.mockRejectedValue(new Error('Runtime installation failed'));
  render(<RuntimeSetup backend={backendWith(undefined, { status: { state: 'missing' } })} />);
  expect(screen.queryByRole('button', { name: /Get help/ })).not.toBeInTheDocument();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Install CLI/ })));
  expect(screen.getByRole('alert')).toHaveTextContent('Runtime installation failed');
  fireEvent.click(screen.getByRole('button', { name: /Get help/ }));
  expect(api.openExternal).toHaveBeenCalledExactlyOnceWith('docs');
});
