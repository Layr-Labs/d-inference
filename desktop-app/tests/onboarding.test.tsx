// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/react';
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
