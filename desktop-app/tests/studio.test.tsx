// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Snapshot } from '../src/shared/contracts';
import { Studio } from '../src/renderer/features/Studio';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

// The endpoint serves Gemma although GPT-OSS is the first downloaded model.
const serving = () =>
  poolSnapshot(
    {},
    {
      activity: { started_at: 1_790_000_000, samples: [] },
      endpoint: {
        base_url: 'http://127.0.0.1:8000/v1',
        authenticated: true,
        models: ['gemma-4-26b'],
      },
    },
  );

it('defaults to the model the endpoint serves, so the example works as copied', () => {
  render(<Studio backend={backendWith(serving())} />);
  expect(screen.getByRole('combobox')).toHaveValue('gemma-4-26b');
  expect(document.querySelector('pre')).toHaveTextContent('"model":"gemma-4-26b"');
});

it('reads keys only on Reveal and supports Hide followed by a fresh Reveal', async () => {
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  render(<Studio backend={backendWith(serving())} />);
  expect(api.read).not.toHaveBeenCalled();
  expect(api.copy).not.toHaveBeenCalled();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-local-test')).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: 'Hide' }));
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
  expect(api.read).toHaveBeenCalledExactlyOnceWith('endpoint-key');
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-local-test')).toBeVisible();
  expect(api.read).toHaveBeenCalledTimes(2);
  expect(api.copy).not.toHaveBeenCalled();
});

it.each(['sk-local-test', 'sk-replacement-test'])(
  'requires a fresh Reveal after stop and reappearance, even when the next key is %s',
  async (nextKey) => {
    const initial = serving();
    api.read
      .mockResolvedValueOnce({ key: 'sk-local-test' })
      .mockResolvedValueOnce({ key: nextKey });
    const view = render(<Studio backend={backendWith(initial)} />);
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
    expect(screen.getByText('sk-local-test')).toBeVisible();
    view.rerender(<Studio backend={backendWith({ ...initial, endpoint: undefined })} />);
    expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Reveal' })).toBeDisabled();
    view.rerender(<Studio backend={backendWith(initial)} />);
    expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
    expect(api.read).toHaveBeenCalledTimes(1);
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
    expect(screen.getByText(nextKey)).toBeVisible();
    expect(api.read).toHaveBeenCalledTimes(2);
  },
);

const replacements: [string, (state: Snapshot) => Snapshot][] = [
  [
    'base URL',
    (state) => ({
      ...state,
      endpoint: { ...state.endpoint!, base_url: 'http://127.0.0.1:8100/v1' },
    }),
  ],
  ['runtime instance', (state) => ({ ...state, installation_id: 'replacement-runtime' })],
  [
    'provider session',
    (state) => ({ ...state, activity: { ...state.activity, started_at: 1_790_000_100 } }),
  ],
];

it.each(replacements)('clears a revealed key when the %s changes', async (_, replace) => {
  const initial = serving();
  api.read
    .mockResolvedValueOnce({ key: 'sk-local-test' })
    .mockResolvedValueOnce({ key: 'sk-replacement-test' });
  const view = render(<Studio backend={backendWith(initial)} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  view.rerender(<Studio backend={backendWith(replace(initial))} />);
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
  expect(api.read).toHaveBeenCalledTimes(1);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-replacement-test')).toBeVisible();
});

it('does not reveal a key for an unauthenticated endpoint or restore one when auth returns', async () => {
  const initial = serving();
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  const view = render(<Studio backend={backendWith(initial)} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  view.rerender(
    <Studio
      backend={backendWith({
        ...initial,
        endpoint: { ...initial.endpoint!, authenticated: false },
      })}
    />,
  );
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
  const reveal = screen.getByRole('button', { name: 'Reveal' });
  expect(reveal).toBeDisabled();
  expect(screen.getByText('No API key required. Accessible only on this Mac.')).toBeVisible();
  fireEvent.click(reveal);
  expect(api.read).toHaveBeenCalledTimes(1);
  view.rerender(<Studio backend={backendWith(initial)} />);
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
});

it('clears the reveal when the runtime disconnects even if its last endpoint snapshot remains', async () => {
  const initial = serving();
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  const view = render(<Studio backend={backendWith(initial)} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  view.rerender(<Studio backend={backendWith(initial, { status: { state: 'connecting' } })} />);
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Reveal' })).toBeDisabled();
  view.rerender(<Studio backend={backendWith(initial)} />);
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
});

it('preserves a reveal, selection and focus across ordinary snapshots and account sign-out', async () => {
  const initial = {
    ...serving(),
    account_revision: 'signed-in',
    account: { signed_in: true, email: 'test@example.test' },
  };
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  const view = render(<Studio backend={backendWith(initial)} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  const select = screen.getByRole('combobox');
  fireEvent.change(select, { target: { value: 'gpt-oss-20b' } });
  const localMode = screen.getByRole('radio', { name: /Local only/ });
  fireEvent.click(localMode);
  select.focus();
  view.rerender(
    <Studio
      backend={backendWith({
        ...initial,
        observed_at: initial.observed_at + 30,
        resource_revision: 'next-snapshot',
        account_revision: 'signed-out',
        account: { signed_in: false },
        endpoint: { ...initial.endpoint!, models: ['qwen-3.5-9b'] },
      })}
    />,
  );
  expect(screen.getByText('sk-local-test')).toBeVisible();
  expect(screen.getByRole('combobox')).toBe(select);
  expect(select).toHaveFocus();
  expect(select).toHaveValue('gpt-oss-20b');
  expect(localMode).toBeChecked();
  expect(api.read).toHaveBeenCalledTimes(1);
});

it('preserves a pending local-only Reveal across routine snapshots in Strict Mode', async () => {
  // Local-only endpoints have no provider session timestamp. Account sign-out does not
  // unlink the provider or rotate the local credential.
  const initial = { ...serving(), activity: { samples: [] }, account_revision: 'signed-in' };
  let resolve!: (value: { key: string }) => void;
  api.read.mockReturnValueOnce(new Promise((done) => (resolve = done)));
  const view = render(<Studio backend={backendWith(initial)} />, { reactStrictMode: true });
  fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
  view.rerender(
    <Studio
      backend={backendWith({
        ...initial,
        observed_at: initial.observed_at + 2,
        account_revision: 'signed-out',
        account: { signed_in: false },
        activity: { ...initial.activity },
        endpoint: { ...initial.endpoint! },
      })}
    />,
  );
  await act(async () => resolve({ key: 'sk-local-test' }));
  expect(screen.getByText('sk-local-test')).toBeVisible();
  expect(api.read).toHaveBeenCalledExactlyOnceWith('endpoint-key');
});

it.each(['stopped', 'restarted'])(
  'ignores a pending key read that resolves while the endpoint is %s',
  async (phase) => {
    const initial = serving();
    let resolve!: (value: { key: string }) => void;
    api.read.mockReturnValueOnce(new Promise((done) => (resolve = done)));
    const view = render(<Studio backend={backendWith(initial)} />);
    fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
    view.rerender(<Studio backend={backendWith({ ...initial, endpoint: undefined })} />);
    if (phase === 'restarted') view.rerender(<Studio backend={backendWith(initial)} />);
    await act(async () => resolve({ key: 'sk-obsolete-test' }));
    view.rerender(<Studio backend={backendWith(initial)} />);
    expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Reveal' })).toBeEnabled();
    expect(api.read).toHaveBeenCalledTimes(1);
  },
);

it.each(replacements)('ignores a pending read from an obsolete %s', async (_, replace) => {
  const initial = serving();
  let resolve!: (value: { key: string }) => void;
  api.read
    .mockReturnValueOnce(new Promise((done) => (resolve = done)))
    .mockResolvedValueOnce({ key: 'sk-current-test' });
  const view = render(<Studio backend={backendWith(initial)} />);
  fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
  view.rerender(<Studio backend={backendWith(replace(initial))} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-current-test')).toBeVisible();
  await act(async () => resolve({ key: 'sk-obsolete-test' }));
  expect(screen.getByText('sk-current-test')).toBeVisible();
  expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
});

it('ignores a pending key read when the endpoint no longer requires authentication', async () => {
  const initial = serving();
  let resolve!: (value: { key: string }) => void;
  api.read.mockReturnValueOnce(new Promise((done) => (resolve = done)));
  const view = render(<Studio backend={backendWith(initial)} />);
  fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
  view.rerender(
    <Studio
      backend={backendWith({
        ...initial,
        endpoint: { ...initial.endpoint!, authenticated: false },
      })}
    />,
  );
  await act(async () => resolve({ key: 'sk-obsolete-test' }));
  expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Reveal' })).toBeDisabled();
  view.rerender(<Studio backend={backendWith(initial)} />);
  expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
});

it('ignores a pending key read across a runtime disconnect and reconnect', async () => {
  const initial = serving();
  let resolve!: (value: { key: string }) => void;
  api.read.mockReturnValueOnce(new Promise((done) => (resolve = done)));
  const view = render(<Studio backend={backendWith(initial)} />);
  fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
  view.rerender(<Studio backend={backendWith(initial, { status: { state: 'connecting' } })} />);
  view.rerender(<Studio backend={backendWith(initial)} />);
  await act(async () => resolve({ key: 'sk-obsolete-test' }));
  expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
});

it.each(['resolves', 'rejects'])(
  'keeps a later explicit Reveal when an older read %s',
  async (outcome) => {
    let resolve!: (value: { key: string }) => void;
    let reject!: (error: Error) => void;
    api.read
      .mockReturnValueOnce(
        new Promise((done, fail) => {
          resolve = done;
          reject = fail;
        }),
      )
      .mockResolvedValueOnce({ key: 'sk-current-test' });
    render(<Studio backend={backendWith(serving())} />);
    fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
    await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
    await act(async () => {
      if (outcome === 'resolves') resolve({ key: 'sk-obsolete-test' });
      else reject(new Error('unavailable'));
    });
    expect(screen.getByText('sk-current-test')).toBeVisible();
    expect(screen.queryByText('sk-obsolete-test')).not.toBeInTheDocument();
    expect(screen.queryByText('Couldn’t read the API key. Try again.')).not.toBeInTheDocument();
  },
);

it('reports a failed key read and allows an explicit retry', async () => {
  api.read
    .mockRejectedValueOnce(new Error('unavailable'))
    .mockResolvedValueOnce({ key: 'sk-local-test' });
  render(<Studio backend={backendWith(serving())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('Couldn’t read the API key. Try again.')).toBeVisible();
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-local-test')).toBeVisible();
  expect(screen.queryByText('Couldn’t read the API key. Try again.')).not.toBeInTheDocument();
});

it('ignores an obsolete key-read failure after stop and reappearance', async () => {
  const initial = serving();
  let reject!: (error: Error) => void;
  api.read.mockReturnValueOnce(new Promise((_, fail) => (reject = fail)));
  const view = render(<Studio backend={backendWith(initial)} />);
  fireEvent.click(screen.getByRole('button', { name: 'Reveal' }));
  view.rerender(<Studio backend={backendWith({ ...initial, endpoint: undefined })} />);
  view.rerender(<Studio backend={backendWith(initial)} />);
  await act(async () => reject(new Error('unavailable')));
  expect(screen.queryByText('Couldn’t read the API key. Try again.')).not.toBeInTheDocument();
});

it('keeps the selected model for Apply but uses a served model in the copied example', async () => {
  api.copy.mockResolvedValue(undefined);
  const backend = backendWith(serving());
  render(<Studio backend={backend} />);
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'qwen-3.5-9b' } });
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Copy example/ })));
  expect(api.copy).toHaveBeenCalledWith(expect.stringContaining('"model":"gemma-4-26b"'));
  await act(async () =>
    fireEvent.click(screen.getByRole('button', { name: /Apply serving mode/ })),
  );
  expect(backend.act).toHaveBeenCalledWith({
    action: 'start',
    models: ['qwen-3.5-9b'],
    local: false,
    endpoint: true,
  });
});

it('reports a failed copy instead of claiming it was copied', async () => {
  api.copy.mockRejectedValue(new Error('denied'));
  render(<Studio backend={backendWith(serving())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Copy example/ })));
  expect(screen.queryByText('Copied')).not.toBeInTheDocument();
  expect(screen.getByText('Couldn’t copy to the clipboard.')).toBeVisible();
});

it('confirms only the value that was copied', async () => {
  api.copy.mockResolvedValue(undefined);
  render(<Studio backend={backendWith(serving())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Copy base URL' })));
  expect(screen.getByRole('button', { name: 'Base URL copied' })).toBeVisible();
  expect(screen.getByRole('button', { name: /Copy example/ })).toBeVisible();
  expect(screen.queryByText('Copied')).not.toBeInTheDocument();
  expect(api.read).not.toHaveBeenCalled();
});

it('copies a placeholder rather than a revealed key and confirms only the example', async () => {
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  api.copy.mockResolvedValue(undefined);
  render(<Studio backend={backendWith(serving())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  await act(async () => fireEvent.click(screen.getByRole('button', { name: /Copy example/ })));
  expect(api.copy).toHaveBeenCalledExactlyOnceWith(
    expect.stringContaining('Authorization: Bearer <your-local-api-key>'),
  );
  expect(api.copy.mock.calls[0][0]).not.toContain('sk-local-test');
  expect(screen.getByRole('button', { name: 'Copy base URL' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Copied' })).toBeVisible();
});
