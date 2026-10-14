// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import type { Snapshot } from '../src/shared/contracts';

let Home: typeof import('../src/renderer/features/Home').Home;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(cleanup);

async function renderHome(state: Snapshot['state']) {
  const backend = await previewBackend();
  backend.state = { ...backend.state!, state, operations: [] };
  const navigate = vi.fn();
  render(<Home backend={backend} navigate={navigate} openMachine={vi.fn()} />);
  return { backend, navigate };
}
const startButton = () => screen.queryByRole('button', { name: 'Start providing' });

it.each(['running', 'stale'] as const)('offers Stop provider while %s', async (state) => {
  const { backend, navigate } = await renderHome(state);
  expect(startButton()).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Stop provider' }));
  expect(backend.act).toHaveBeenCalledWith({ action: 'stop' });
  expect(navigate).not.toHaveBeenCalled();
});

it.each([
  ['starting', 'Starting provider'],
  ['draining', 'Finishing requests'],
] as const)('waits out %s without offering Start or Stop', async (state, label) => {
  const { backend, navigate } = await renderHome(state);
  expect(startButton()).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Stop provider' })).not.toBeInTheDocument();
  const button = screen.getByRole('button', { name: label });
  expect(button).toBeDisabled();
  fireEvent.click(button);
  expect(backend.act).not.toHaveBeenCalled();
  expect(navigate).not.toHaveBeenCalled();
});

it('opens Models to start a stopped provider', async () => {
  const { backend, navigate } = await renderHome('stopped');
  fireEvent.click(startButton()!);
  expect(navigate).toHaveBeenCalledWith('models');
  expect(backend.act).not.toHaveBeenCalled();
});
