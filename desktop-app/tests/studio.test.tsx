// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Studio } from '../src/renderer/features/Studio';
import { backendWith } from './onboardingFixtures';
import { poolSnapshot } from './modelsFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

// The endpoint serves Gemma although GPT-OSS is the first downloaded model.
const serving = () =>
  poolSnapshot(
    {},
    {
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

it('removes a revealed key when the endpoint stops', async () => {
  api.read.mockResolvedValue({ key: 'sk-local-test' });
  const view = render(<Studio backend={backendWith(serving())} />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Reveal' })));
  expect(screen.getByText('sk-local-test')).toBeVisible();
  view.rerender(<Studio backend={backendWith({ ...serving(), endpoint: undefined })} />);
  expect(screen.queryByText('sk-local-test')).not.toBeInTheDocument();
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
});
