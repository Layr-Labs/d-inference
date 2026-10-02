// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { BackendState } from '../src/renderer/useBackend';
import { previewAPI } from '../src/renderer/preview';
import App from '../src/renderer/App';

let backend: BackendState;
vi.mock('../src/renderer/useBackend', () => ({
  isPreview: false,
  api: { onNavigate: () => () => {} },
  useBackend: () => backend,
}));
afterEach(cleanup);

function connectedBackend(state: BackendState['state']): BackendState {
  return {
    status: { state: 'ready' },
    state,
    cloud: undefined,
    network: undefined,
    cooling: undefined,
    release: undefined,
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn().mockResolvedValue(true),
    refresh: vi.fn(),
  };
}

it('keeps first-run onboarding open when the runtime connects', async () => {
  localStorage.clear();
  backend = {
    status: { state: 'missing' },
    state: undefined,
    cloud: undefined,
    network: undefined,
    cooling: undefined,
    release: undefined,
    leaders: [],
    leaderError: '',
    error: '',
    setError: vi.fn(),
    busy: false,
    act: vi.fn(),
    refresh: vi.fn(),
  };
  const { rerender } = render(<App />);
  expect(screen.getByRole('heading', { name: 'Connect your Mac.' })).toBeVisible();
  backend = { ...backend, status: { state: 'ready' }, state: await previewAPI.read('state') };
  rerender(<App />);
  expect(screen.getByRole('heading', { name: 'This Mac is ready.' })).toBeVisible();
  expect(screen.queryByRole('heading', { name: 'Your contribution' })).not.toBeInTheDocument();
});

it('starts without a terms checkbox and states the agreement next to the start action', async () => {
  localStorage.clear();
  backend = connectedBackend(await previewAPI.read('state'));
  render(<App />);
  fireEvent.click(screen.getByRole('button', { name: /Continue/ }));
  fireEvent.click(screen.getByRole('radio', { name: /GPT-OSS 20B/ }));
  fireEvent.click(screen.getByRole('button', { name: /Continue/ }));
  expect(screen.getByRole('heading', { name: 'Ready when you are.' })).toBeVisible();
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
  expect(screen.getByText(/By turning on, you agree to our/)).toBeVisible();
  expect(screen.getByRole('button', { name: /Terms of Service/ })).toBeVisible();
  const start = screen.getByRole('button', { name: /Start providing/ });
  expect(start).toBeEnabled();
  fireEvent.click(start);
  await waitFor(() =>
    expect(backend.act).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'start', models: ['gpt-oss-20b'] }),
      true,
    ),
  );
});
