// @vitest-environment jsdom
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { afterEach, expect, it, vi } from 'vitest';
import { OperationFeed } from '../src/renderer/components/operations/OperationFeed';
import App from '../src/renderer/App';
import { backendWith, operation, snapshot } from './onboardingFixtures';

const runtime = vi.hoisted(() => ({ backend: undefined as unknown }));
vi.mock('../src/renderer/useBackend', () => ({
  api: undefined,
  isPreview: true,
  useBackend: () => runtime.backend,
}));
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  localStorage.clear();
});
const backend = (state: Parameters<typeof operation>[0] = 'succeeded', message = 'Saved.') =>
  backendWith(snapshot({ operations: [operation(state, message, 'settings')] }));

it('expires a success after ten seconds without restarting on repeated snapshots', () => {
  vi.useFakeTimers();
  const { rerender } = render(<OperationFeed backend={backend()} />);
  expect(screen.getByRole('status')).toHaveTextContent('Settings · Complete');
  act(() => {
    vi.advanceTimersByTime(6000);
  });
  rerender(<OperationFeed backend={backend()} />);
  act(() => {
    vi.advanceTimersByTime(3999);
  });
  expect(screen.getByRole('status')).toBeVisible();
  act(() => {
    vi.advanceTimersByTime(1);
  });
  expect(screen.queryByRole('status')).not.toBeInTheDocument();
});

it('starts the countdown on completion, and cancels it when a new operation replaces it', () => {
  vi.useFakeTimers();
  const running = backend('running');
  const { rerender } = render(<OperationFeed backend={running} />);
  act(() => {
    vi.advanceTimersByTime(60_000);
  });
  expect(screen.getByRole('status')).toBeVisible();
  rerender(<OperationFeed backend={backend()} />);
  act(() => {
    vi.advanceTimersByTime(9000);
  });
  const next = backend();
  next.state!.operations[0].id = 'second-operation';
  rerender(<OperationFeed backend={next} />);
  act(() => {
    vi.advanceTimersByTime(9999);
  });
  expect(screen.getByRole('status')).toBeVisible();
  act(() => {
    vi.advanceTimersByTime(1);
  });
  expect(screen.queryByRole('status')).not.toBeInTheDocument();
});

it('keeps a failure until Close and remembers dismissal across remounts', () => {
  vi.useFakeTimers();
  const failure = backend('failed', 'Permission denied');
  const { unmount } = render(<OperationFeed backend={failure} />);
  act(() => {
    vi.advanceTimersByTime(120_000);
  });
  expect(screen.getByRole('alert')).toHaveTextContent('Settings · Failed');
  fireEvent.click(screen.getByRole('button', { name: 'Close notification' }));
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  unmount();
  render(<OperationFeed backend={failure} />);
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
});

it('does not revive an old completed operation when the app reopens', () => {
  vi.useFakeTimers();
  const previous = backend();
  previous.state!.operations[0].finished_at = (Date.now() - 11_000) / 1000;
  render(<OperationFeed backend={previous} />);
  expect(screen.queryByRole('status')).not.toBeInTheDocument();
});

it('shows immediate action errors at the bottom and closes matching failed operation feedback once', () => {
  vi.useFakeTimers();
  const failure = backend('failed', 'Permission denied');
  failure.error = 'Permission denied';
  const { rerender } = render(<OperationFeed backend={failure} />);
  expect(screen.getAllByRole('alert')).toHaveLength(1);
  expect(screen.getByLabelText('Operation notification').parentElement).toBe(document.body);
  act(() => {
    vi.advanceTimersByTime(120_000);
  });
  fireEvent.click(screen.getByRole('button', { name: 'Close notification' }));
  expect(failure.setError).toHaveBeenCalledWith('');
  rerender(<OperationFeed backend={{ ...failure, error: '' }} />);
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
});

it('uses one global bottom notification on every page and preserves its deadline through navigation', () => {
  vi.useFakeTimers();
  runtime.backend = backend();
  render(<App />);
  const toast = screen.getByLabelText('Operation notification');
  expect(toast.parentElement).toBe(document.body);
  act(() => {
    vi.advanceTimersByTime(6000);
  });
  for (const page of ['My Macs', 'Leaderboard', 'Updates', 'Home']) {
    fireEvent.click(screen.getByRole('button', { name: page }));
    expect(screen.getAllByLabelText('Operation notification')).toHaveLength(1);
    expect(screen.getByLabelText('Operation notification')).toBe(toast);
    expect(document.querySelector('.operation-inline')).not.toBeInTheDocument();
  }
  act(() => {
    vi.advanceTimersByTime(4000);
  });
  expect(screen.queryByLabelText('Operation notification')).not.toBeInTheDocument();
});
