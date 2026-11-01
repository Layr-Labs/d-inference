// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { OperationFeed } from '../src/renderer/components/UI';
import { AccountControl } from '../src/renderer/components/AccountControl';
import { backendWith, operation, snapshot } from './onboardingFixtures';

const bridge = vi.hoisted(() => ({ copy: vi.fn(), openExternal: vi.fn() }));
vi.mock('../src/renderer/useBackend', () => ({ api: bridge }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
  localStorage.clear();
});
const pending = { ...operation('running', 'Working…', 'account-signin'), cancellable: true };
const link = {
  code: 'ABCD-EFGH',
  url: 'https://console.darkbloom.dev/link',
  expires_at: 1_790_001_000,
  state: 'waiting',
};
const login = (overrides: Parameters<typeof snapshot>[0] = {}) =>
  backendWith(
    snapshot({ capabilities: ['account-signin'], operations: [pending], link, ...overrides }),
  );

it('opens immediately, waits for a fresh code, and opens the browser only on an explicit click', async () => {
  const backend = login({ operations: [operation('failed', 'Old failure', 'account-signin')] });
  let finish!: (value: boolean) => void;
  vi.mocked(backend.act).mockImplementation(
    () =>
      new Promise((resolve) => {
        finish = resolve;
      }),
  );
  const { rerender } = render(<AccountControl backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
  expect(screen.getByRole('dialog', { name: 'Sign in to Darkbloom' })).toBeVisible();
  expect(screen.getByText('Getting a connection code…')).toBeVisible();
  expect(screen.getByRole('button', { name: 'Continue in browser' })).toBeDisabled();
  expect(screen.queryByText(link.code)).not.toBeInTheDocument();
  expect(bridge.openExternal).not.toHaveBeenCalled();
  rerender(<AccountControl backend={login({ operations: [{ ...pending, id: 'fresh-login' }] })} />);
  expect(screen.getByLabelText('Connection code ABCD-EFGH')).toBeVisible();
  expect(bridge.openExternal).not.toHaveBeenCalled();
  expect(screen.getByText('Enter this code in your browser.')).toBeVisible();
  expect(
    within(screen.getByRole('dialog')).queryByText('Waiting for approval'),
  ).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Continue in browser' }));
  expect(bridge.openExternal).toHaveBeenCalledExactlyOnceWith('link');
  expect(await screen.findByText('Approve the connection in your browser.')).toBeVisible();
  finish(true);
  await waitFor(() =>
    expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'account-signin' }),
  );
});

it('reopens pending sign-in without a duplicate request and restores keyboard focus', async () => {
  const backend = login();
  backend.busy = true;
  render(
    <>
      <AccountControl backend={backend} />
      <OperationFeed backend={backend} />
    </>,
  );
  const button = screen.getByRole('button', { name: 'Continue sign-in' });
  button.focus();
  fireEvent.click(button);
  expect(screen.getAllByLabelText('Connection code ABCD-EFGH')).toHaveLength(1);
  fireEvent.click(screen.getByRole('button', { name: 'Copy code' }));
  expect(bridge.copy).toHaveBeenCalledWith(link.code);
  await screen.findByRole('button', { name: 'Copied' });
  fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape' });
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  expect(button).toHaveFocus();
  fireEvent.click(button);
  expect(screen.getByLabelText('Connection code ABCD-EFGH')).toBeVisible();
  expect(backend.act).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
  expect(backend.act).toHaveBeenCalledWith({ action: 'cancel', operation: pending.id });
});

it('removes expired codes, retains failure details, and starts a fresh attempt on retry', async () => {
  const { rerender } = render(<AccountControl backend={login()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Continue sign-in' }));
  const failed = login({
    operations: [{ ...pending, state: 'failed', message: 'Device code expired' }],
  });
  rerender(<AccountControl backend={failed} />);
  expect(screen.queryByText(link.code)).not.toBeInTheDocument();
  expect(screen.getByText('Could not complete sign-in.')).toBeVisible();
  expect(screen.getByText('Device code expired')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Try again' }));
  await waitFor(() => expect(failed.act).toHaveBeenCalledWith({ action: 'account-signin' }));
  expect(screen.getByText('Getting a connection code…')).toBeVisible();
});

it('shows a recoverable error if the login request cannot start', async () => {
  const backend = login({ operations: [], link: undefined });
  vi.mocked(backend.act).mockResolvedValue(false);
  backend.error = 'Coordinator unavailable';
  render(<AccountControl backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Sign in' }));
  expect(await screen.findByText('Could not complete sign-in.')).toBeVisible();
  expect(screen.getByRole('alert')).toHaveTextContent('Coordinator unavailable');
  expect(screen.getByRole('button', { name: 'Try again' })).toBeEnabled();
});

it('confirms approval in the dialog and switches the footer to Account', () => {
  const { rerender } = render(<AccountControl backend={login()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Continue sign-in' }));
  rerender(
    <AccountControl
      backend={login({
        operations: [{ ...pending, state: 'succeeded' }],
        account: { signed_in: true },
      })}
    />,
  );
  expect(screen.getByText('You’re signed in.')).toBeVisible();
  expect(screen.queryByText(link.code)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Account' })).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Done' }));
  fireEvent.click(screen.getByRole('button', { name: 'Account' }));
  expect(screen.getByRole('dialog', { name: 'Your account' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Sign out' })).toBeEnabled();
});

it('keeps clipboard and browser failures actionable inside the dialog', async () => {
  bridge.copy.mockRejectedValue(new Error('Clipboard unavailable'));
  bridge.openExternal.mockRejectedValue(new Error('Browser unavailable'));
  render(<AccountControl backend={login()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Continue sign-in' }));
  fireEvent.click(screen.getByRole('button', { name: 'Copy code' }));
  expect(await screen.findByRole('alert')).toHaveTextContent('Could not copy the connection code.');
  fireEvent.click(screen.getByRole('button', { name: 'Continue in browser' }));
  await waitFor(() =>
    expect(screen.getByRole('alert')).toHaveTextContent('Could not open sign-in. Try again.'),
  );
});

it('shows the signed-in email in the footer and hides it immediately after sign-out', () => {
  const email = 'a.long.account.email.address@example.com';
  const { rerender } = render(
    <AccountControl backend={login({ operations: [], account: { signed_in: true, email } })} />,
  );
  const control = screen.getByRole('button', { name: `Account ${email}` });
  expect(within(control).getByText(email)).toHaveAttribute('title', email);
  expect(within(control).getByText('Signed in')).toBeVisible();
  fireEvent.click(control);
  expect(within(screen.getByRole('dialog')).getByText(email)).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Done' }));
  rerender(
    <AccountControl backend={login({ operations: [], account: { signed_in: false, email } })} />,
  );
  expect(screen.getByRole('button', { name: 'Sign in' })).toBeVisible();
  expect(screen.queryByText(email)).not.toBeInTheDocument();
});
