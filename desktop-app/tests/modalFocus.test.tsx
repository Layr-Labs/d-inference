// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Modal } from '../src/renderer/components/UI';

afterEach(cleanup);

// Sign-in swaps its view when approval arrives, removing the control that had focus.
function signIn(approved: boolean, onClose: () => void) {
  return (
    <Modal title="Sign in to Darkbloom" onClose={onClose}>
      {approved ? (
        <details>
          <summary>Details</summary>
          <p>Signed in.</p>
        </details>
      ) : (
        <button>Continue in browser</button>
      )}
    </Modal>
  );
}

it('keeps focus, Escape and the Tab trap in a dialog whose focused control is replaced', async () => {
  const onClose = vi.fn();
  const view = render(signIn(false, onClose));
  screen.getByRole('button', { name: 'Continue in browser' }).focus();
  await act(async () => view.rerender(signIn(true, onClose)));
  const dialog = screen.getByRole('dialog', { name: 'Sign in to Darkbloom' });
  expect(dialog).toContainElement(document.activeElement as HTMLElement);

  fireEvent.keyDown(document.activeElement!, { key: 'Tab' });
  // Tab from the dialog itself lands on its first control, never the page behind it.
  expect(dialog).toContainElement(document.activeElement as HTMLElement);

  // Focus lost to the page behind the dialog.
  (document.activeElement as HTMLElement).blur();
  expect(document.activeElement).toBe(document.body);
  fireEvent.keyDown(document.body, { key: 'Tab', shiftKey: true });
  expect(document.activeElement).toBe(screen.getByText('Details'));

  fireEvent.keyDown(document.body, { key: 'Escape' });
  expect(onClose).toHaveBeenCalled();
});

it('keeps focus where the user put it when the dialog re-renders with a new onClose', async () => {
  const view = render(
    <Modal title="Turn off automatic updates?" onClose={() => {}}>
      <button>Keep enabled</button>
      <button>Turn off</button>
    </Modal>,
  );
  screen.getByRole('button', { name: 'Turn off' }).focus();
  // A state push re-renders the page, and the caller passes a fresh handler.
  for (let i = 0; i < 3; i++)
    await act(async () =>
      view.rerender(
        <Modal title="Turn off automatic updates?" onClose={() => {}}>
          <button>Keep enabled</button>
          <button>Turn off</button>
        </Modal>,
      ),
    );
  expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Turn off' }));
});
