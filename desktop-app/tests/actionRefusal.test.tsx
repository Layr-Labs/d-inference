// @vitest-environment jsdom
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';

beforeEach(() => vi.resetModules());
afterEach(() => {
  cleanup();
  delete (window as any).darkbloom;
});

// A refused action as Electron delivers it: `ipcRenderer.invoke` rejects with the main process's
// error behind Electron's own prefix. Here it is the runtime's refusal of the app's Start on a pair
// with no model yet. The real `useBackend` and failure toast show only the action's own words.
it('shows a refused action’s own words in the failure toast, without Electron’s prefix', async () => {
  const words =
    'No model was chosen for the pair yet: run `darkbloom start` in a terminal to choose one.';
  const refusal = new Error(`Error invoking remote method 'backend:act': Error: ${words}`);
  (window as any).darkbloom = {
    status: async () => ({ state: 'ready' }),
    system: async () => ({ macosVersion: '27.0' }),
    onState: () => () => {},
    onStatus: () => () => {},
    read: () => new Promise(() => {}),
    act: vi.fn().mockRejectedValue(refusal),
  };
  const { useBackend } = await import('../src/renderer/useBackend');
  const { OperationFeed } = await import('../src/renderer/components/UI');
  function PairedStart() {
    const backend = useBackend();
    const start = () => void backend.act({ action: 'start', models: [], local: false }, true);
    return (
      <>
        <button onClick={start}>Start serving</button>
        <OperationFeed backend={backend} />
      </>
    );
  }
  render(<PairedStart />);
  await act(async () => fireEvent.click(screen.getByRole('button', { name: 'Start serving' })));
  const toast = screen.getByRole('alert', { name: 'Operation notification' });
  expect(within(toast).getByText('Action failed')).toBeInTheDocument();
  expect(within(toast).getByText(words)).toBeInTheDocument();
  expect(toast).not.toHaveTextContent('Error invoking remote method');
});
