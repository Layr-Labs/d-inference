// @vitest-environment jsdom
import { afterEach, beforeAll, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Settings } from '../src/renderer/features/Settings';
import { backendWith, operation, snapshot } from './onboardingFixtures';

let Home: typeof import('../src/renderer/features/Home').Home;
let previewBackend: typeof import('./previewBackend').previewBackend;
beforeAll(async () => {
  window.history.replaceState({}, '', '/?preview');
  ({ Home } = await import('../src/renderer/features/Home'));
  ({ previewBackend } = await import('./previewBackend'));
});
afterEach(cleanup);

it('asks before unlinking this Mac', () => {
  const backend = backendWith(snapshot({ linked: true }));
  render(<Settings backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Unlink this Mac' }));
  const dialog = screen.getByRole('dialog', { name: 'Unlink this Mac?' });
  expect(backend.act).not.toHaveBeenCalled();
  fireEvent.click(within(dialog).getByRole('button', { name: 'Keep linked' }));
  expect(backend.act).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole('button', { name: 'Unlink this Mac' }));
  fireEvent.click(
    within(screen.getByRole('dialog')).getByRole('button', { name: 'Unlink this Mac' }),
  );
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'unlink' });
});

it('does not request another link while one is pending', async () => {
  const base = await previewBackend();
  const unlinked = { ...base.state!, linked: false };
  const { rerender } = render(
    <Home backend={{ ...base, state: unlinked }} navigate={() => {}} openMachine={() => {}} />,
  );
  expect(screen.getByRole('button', { name: 'Link account' })).toBeEnabled();
  rerender(
    <Home
      backend={{
        ...base,
        state: { ...unlinked, operations: [operation('running', 'Linking…', 'link')] },
      }}
      navigate={() => {}}
      openMachine={() => {}}
    />,
  );
  expect(screen.getByRole('button', { name: 'Link account' })).toBeDisabled();
  const link = {
    url: 'https://console.darkbloom.dev/link',
    code: 'KXQF-7M2P',
    expires_at: 1,
    state: 'waiting',
  };
  rerender(
    <Home
      backend={{ ...base, state: { ...unlinked, link } }}
      navigate={() => {}}
      openMachine={() => {}}
    />,
  );
  expect(screen.queryByRole('button', { name: 'Link account' })).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: /KXQF-7M2P/ })).toBeVisible();
});
