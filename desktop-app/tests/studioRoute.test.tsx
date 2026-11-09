// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Studio } from '../src/renderer/features/Studio';
import { backendWith } from './onboardingFixtures';
import { localSnapshot } from './studioFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

const routing = () =>
  within(screen.getByRole('region', { name: 'When this Mac can’t take a request' }));

it('keeps requests on this Mac until an account key is saved, and says why', () => {
  render(<Studio backend={backendWith(localSnapshot())} />);
  const section = routing();
  expect(section.getByRole('radio', { name: 'Only this Mac' })).toBeChecked();
  for (const name of ['Only my Macs (free)', 'My Macs first']) {
    const option = section.getByRole('radio', { name });
    expect(option).toBeDisabled();
    expect(option).toHaveAccessibleDescription(/Needs your account API key\.$/);
  }
  expect(section.getByRole('radio', { name: 'My Macs first' })).toHaveAccessibleDescription(
    'Your other Macs, then the Darkbloom network, billed to your balance. Needs your account API key.',
  );
  expect(section.getByRole('button', { name: 'Save' })).toBeDisabled();
});

it('takes only my Macs once a key is saved and no route is, then saves another route', async () => {
  const backend = backendWith(localSnapshot({ route_key: true }));
  render(<Studio backend={backend} />);
  const section = routing();
  expect(section.getByRole('radio', { name: 'Only my Macs (free)' })).toBeChecked();
  fireEvent.click(section.getByRole('radio', { name: 'My Macs first' }));
  await act(async () => fireEvent.click(section.getByRole('button', { name: 'Save' })));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith(
    { action: 'route', route: 'my-macs-first' },
    true,
  );
});

it('follows the saved route', () => {
  const view = render(<Studio backend={backendWith(localSnapshot({ route_key: true }))} />);
  fireEvent.click(routing().getByRole('radio', { name: 'Only this Mac' }));
  view.rerender(
    <Studio backend={backendWith(localSnapshot({ route_key: true, route: 'my-macs-first' }))} />,
  );
  expect(routing().getByRole('radio', { name: 'My Macs first' })).toBeChecked();
  expect(routing().getByRole('button', { name: 'Save' })).toBeDisabled();
});

it('sends the account key once, clears it as it is sent and never shows it', async () => {
  let finish!: (saved: boolean) => void;
  const backend = backendWith(localSnapshot());
  vi.mocked(backend.act).mockReturnValueOnce(new Promise((done) => (finish = done)));
  const { container } = render(<Studio backend={backend} />);
  const field = routing().getByLabelText('Account API key');
  expect(field).toHaveAttribute('type', 'password');
  expect(field).toHaveAttribute('autocomplete', 'off');
  const save = routing().getByRole('button', { name: 'Save key' });
  expect(save).toBeDisabled();
  fireEvent.change(field, { target: { value: '  sk-account-test\n' } });
  fireEvent.click(save);
  // Cleared before the runtime answers, and never in the page.
  expect(field).toHaveValue('');
  expect(container).not.toHaveTextContent('sk-account-test');
  expect(backend.act).toHaveBeenCalledExactlyOnceWith(
    { action: 'route_key', key: 'sk-account-test' },
    true,
  );
  await act(async () => finish(true));
  expect(field).toHaveValue('');
});

it.each([
  [
    'dk-local-abc',
    'That is this Mac’s local API key; use an account API key from the Darkbloom console.',
  ],
  ['sk account', 'An API key has no spaces, line breaks or non-ASCII characters.'],
  ['sk-ключ', 'An API key has no spaces, line breaks or non-ASCII characters.'],
  ['k'.repeat(513), 'That is longer than any Darkbloom API key.'],
])('refuses %j in the CLI’s words before sending it', (value, refusal) => {
  const backend = backendWith(localSnapshot());
  render(<Studio backend={backend} />);
  const field = routing().getByLabelText('Account API key');
  fireEvent.change(field, { target: { value } });
  expect(field).toHaveAttribute('aria-invalid', 'true');
  expect(field).toHaveAccessibleDescription(refusal);
  const save = routing().getByRole('button', { name: 'Save key' });
  expect(save).toBeDisabled();
  fireEvent.submit(save.closest('form')!);
  expect(backend.act).not.toHaveBeenCalled();
});

it('says a key is saved without showing it, and replaces it on request', async () => {
  const backend = backendWith(localSnapshot({ route_key: true }));
  render(<Studio backend={backend} />);
  const section = routing();
  expect(section.getByText('Key saved')).toBeVisible();
  expect(section.queryByLabelText('Account API key')).not.toBeInTheDocument();
  fireEvent.click(section.getByRole('button', { name: 'Replace' }));
  fireEvent.change(section.getByLabelText('Account API key'), {
    target: { value: 'sk-new-test' },
  });
  fireEvent.click(section.getByRole('button', { name: 'Cancel' }));
  expect(section.getByText('Key saved')).toBeVisible();
  // Cancelled input is gone: Replace starts empty.
  fireEvent.click(section.getByRole('button', { name: 'Replace' }));
  expect(section.getByLabelText('Account API key')).toHaveValue('');
  fireEvent.change(section.getByLabelText('Account API key'), {
    target: { value: 'sk-new-test' },
  });
  await act(async () => fireEvent.click(section.getByRole('button', { name: 'Save key' })));
  expect(backend.act).toHaveBeenCalledWith({ action: 'route_key', key: 'sk-new-test' }, true);
  expect(section.getByText('Key saved')).toBeVisible();
});

it('keeps the field after a refused key, empty, for another try', async () => {
  const backend = backendWith(localSnapshot());
  vi.mocked(backend.act).mockResolvedValueOnce(false);
  render(<Studio backend={backend} />);
  fireEvent.change(routing().getByLabelText('Account API key'), {
    target: { value: 'sk-refused-test' },
  });
  await act(async () => fireEvent.click(routing().getByRole('button', { name: 'Save key' })));
  expect(routing().getByLabelText('Account API key')).toHaveValue('');
  expect(routing().queryByText('Key saved')).not.toBeInTheDocument();
});
