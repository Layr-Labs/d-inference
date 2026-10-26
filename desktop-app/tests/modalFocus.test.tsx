// @vitest-environment jsdom
import { StrictMode } from 'react';
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
  const first = screen.getByRole('button', { name: 'Close dialog' });
  const last = screen.getByText('Details');
  expect(dialog).toHaveFocus();

  fireEvent.keyDown(dialog, { key: 'Tab' });
  expect(first).toHaveFocus();
  dialog.focus();
  fireEvent.keyDown(dialog, { key: 'Tab', shiftKey: true });
  expect(last).toHaveFocus();
  fireEvent.keyDown(last, { key: 'Tab' });
  expect(first).toHaveFocus();
  fireEvent.keyDown(first, { key: 'Tab', shiftKey: true });
  expect(last).toHaveFocus();

  // Focus lost to the page behind the dialog.
  (document.activeElement as HTMLElement).blur();
  expect(document.activeElement).toBe(document.body);
  fireEvent.keyDown(document.body, { key: 'Tab', shiftKey: true });
  expect(last).toHaveFocus();

  fireEvent.keyDown(document.body, { key: 'Escape' });
  expect(onClose).toHaveBeenCalled();
});

it('keeps focus where the user put it when the dialog re-renders with a new onClose', async () => {
  const originalClose = vi.fn();
  const latestClose = vi.fn();
  const view = render(
    <Modal title="Turn off automatic updates?" onClose={originalClose}>
      <button>Keep enabled</button>
      <button>Turn off</button>
    </Modal>,
  );
  screen.getByRole('button', { name: 'Turn off' }).focus();
  // A state push re-renders the page, and the caller passes a fresh handler.
  for (let i = 0; i < 3; i++)
    await act(async () =>
      view.rerender(
        <Modal title="Turn off automatic updates?" onClose={i === 2 ? latestClose : vi.fn()}>
          <button>Keep enabled</button>
          <button>Turn off</button>
        </Modal>,
      ),
    );
  expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Turn off' }));
  fireEvent.keyDown(document.activeElement!, { key: 'Escape' });
  expect(latestClose).toHaveBeenCalledOnce();
  expect(originalClose).not.toHaveBeenCalled();
});

it('leaves interior Tab and Escape to the topmost dialog', () => {
  const lowerClose = vi.fn();
  const upperClose = vi.fn();
  render(
    <>
      <Modal title="Lower dialog" onClose={lowerClose}>
        <button>Lower action</button>
      </Modal>
      <Modal title="Upper dialog" onClose={upperClose}>
        <button>Upper first</button>
        <button>Upper last</button>
      </Modal>
    </>,
  );
  const first = screen.getByRole('button', { name: 'Upper first' });
  first.focus();
  const event = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
  act(() => first.dispatchEvent(event));
  // jsdom does not perform native Tab traversal. An interior Tab must be left to the browser.
  expect(event.defaultPrevented).toBe(false);
  expect(first).toHaveFocus();
  fireEvent.keyDown(first, { key: 'Escape' });
  expect(upperClose).toHaveBeenCalledOnce();
  expect(lowerClose).not.toHaveBeenCalled();
});

it('ignores lower-dialog subtree changes and releases ownership after Strict Mode cleanup', async () => {
  const onClose = vi.fn();
  const dialogs = (open: boolean, replaced = false) => (
    <>
      <button>Open dialogs</button>
      {open && (
        <>
          <Modal title="Lower dialog" onClose={vi.fn()}>
            {replaced ? <input aria-label="Lower input" /> : <button>Lower action</button>}
          </Modal>
          <Modal title="Upper dialog" onClose={onClose}>
            <button>Upper action</button>
          </Modal>
        </>
      )}
    </>
  );
  const view = render(dialogs(false), { wrapper: StrictMode });
  const trigger = screen.getByRole('button', { name: 'Open dialogs' });
  trigger.focus();
  view.rerender(dialogs(true));
  const upper = screen.getByRole('button', { name: 'Upper action' });
  upper.focus();

  // Replace an element, not just its text, so the obscured dialog's observer runs.
  await act(async () => view.rerender(dialogs(true, true)));
  expect(screen.getByRole('textbox', { name: 'Lower input' })).toBeInTheDocument();
  expect(upper).toHaveFocus();
  fireEvent.keyDown(upper, { key: 'Escape' });
  expect(onClose).toHaveBeenCalledOnce();

  view.rerender(dialogs(false));
  expect(trigger).toHaveFocus();
  const escape = new KeyboardEvent('keydown', {
    key: 'Escape',
    bubbles: true,
    cancelable: true,
  });
  act(() => trigger.dispatchEvent(escape));
  expect(escape.defaultPrevented).toBe(false);
  expect(onClose).toHaveBeenCalledOnce();
});

it.each([false, true])('restores focus when the lower dialog closes first: %s', (lowerFirst) => {
  const dialogs = (lower: boolean, upper: boolean) => (
    <>
      <button>Open dialogs</button>
      {lower && (
        <Modal title="Lower dialog" onClose={vi.fn()}>
          <button>Lower action</button>
        </Modal>
      )}
      {upper && (
        <Modal title="Upper dialog" onClose={vi.fn()}>
          <button>Upper action</button>
        </Modal>
      )}
    </>
  );
  const view = render(dialogs(false, false), { wrapper: StrictMode });
  const trigger = screen.getByRole('button', { name: 'Open dialogs' });
  trigger.focus();
  view.rerender(dialogs(true, false));
  const lowerAction = screen.getByRole('button', { name: 'Lower action' });
  lowerAction.focus();
  view.rerender(dialogs(true, true));
  const upperAction = screen.getByRole('button', { name: 'Upper action' });
  upperAction.focus();

  view.rerender(dialogs(!lowerFirst, lowerFirst));
  expect(lowerFirst ? upperAction : lowerAction).toHaveFocus();
  view.rerender(dialogs(false, false));
  expect(trigger).toHaveFocus();
});
