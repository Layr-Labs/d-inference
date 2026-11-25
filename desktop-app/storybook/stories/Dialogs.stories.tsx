import { useCallback, useEffect, useState, useSyncExternalStore, type ComponentType, type ReactNode } from 'react';
import type { Meta, StoryObj } from '@storybook/react-vite';
import { userEvent, within } from 'storybook/test';
import { Modal as ModalBefore } from '../src/before/desktop-app/src/renderer/components/UI';
import { Modal as ModalAfter } from '../src/after/desktop-app/src/renderer/components/UI';
import { Compare } from './support/Compare';
import { resetBridges, type Version } from './support/bridge';

const meta: Meta = { title: 'Fixes/Sign-in dialog' };
export default meta;
type Story = StoryObj;

type ModalType = ComponentType<{ title: string; children: ReactNode; onClose: () => void }>;

// Only one dialog may be open at a time: the fixed version listens to keys on the document.
let active: Version | null = null;
const listeners = new Set<() => void>();
const setActive = (version: Version | null) => {
  active = version;
  listeners.forEach((listener) => listener());
};
const useActive = () =>
  useSyncExternalStore(
    (listener) => (listeners.add(listener), () => void listeners.delete(listener)),
    () => active,
  );

function describeFocus() {
  const element = document.activeElement as HTMLElement | null;
  if (!element || element === document.body) return 'the page behind the dialog (body)';
  if (element.getAttribute('role') === 'dialog') return 'the dialog itself';
  return `“${(element.getAttribute('aria-label') || element.textContent || element.tagName).trim()}”`;
}

function SignInDemo({ version, Modal }: { version: Version; Modal: ModalType }) {
  const open = useActive() === version;
  const [approved, setApproved] = useState(false);
  const [focus, setFocus] = useState('');
  const [escape, setEscape] = useState('');
  // Stable, as in AccountControl; a new function each render would re-run the dialog's effect.
  const close = useCallback(() => setActive(null), []);
  useEffect(() => {
    const timer = setInterval(() => setFocus(describeFocus()), 150);
    return () => clearInterval(timer);
  }, []);
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape' || active !== version) return;
      const at = describeFocus();
      setTimeout(
        () =>
          setEscape(
            `Escape pressed with focus on ${at}: ${active === version ? 'the dialog stayed open' : 'the dialog closed'}`,
          ),
        50,
      );
    };
    document.addEventListener('keydown', keydown, true);
    return () => document.removeEventListener('keydown', keydown, true);
  }, [version]);
  return (
    <div className="sb-demo">
      <button
        className="button"
        onClick={() => {
          setApproved(false);
          setEscape('');
          setActive(version);
        }}
      >
        Open sign-in dialog
      </button>
      <p className="sb-observed">
        Dialog: <b>{open ? 'open' : 'closed'}</b>
        <br />
        Keyboard focus: <b>{open || focus ? focus : '—'}</b>
        {escape && (
          <>
            <br />
            <b>{escape}</b>
          </>
        )}
      </p>
      {open && (
        <Modal title="Sign in to Darkbloom" onClose={close}>
          {approved ? (
            <>
              <p>Signed in. Your earnings will appear shortly.</p>
              <details>
                <summary>Details</summary>
                <p>Approved in the browser.</p>
              </details>
            </>
          ) : (
            <>
              <p>Enter this code in your browser.</p>
              <button className="button primary" onClick={() => setApproved(true)}>
                Continue in browser
              </button>
            </>
          )}
        </Modal>
      )}
    </div>
  );
}

export const FocusAcrossContentChange: Story = {
  name: '#1466 Dialog focus when its content changes',
  beforeEach: () => {
    resetBridges();
    setActive(null);
  },
  play: async ({ canvasElement }) => {
    for (const pane of canvasElement.querySelectorAll<HTMLElement>('.sb-pane')) {
      const scope = within(pane);
      await userEvent.click(scope.getByRole('button', { name: 'Open sign-in dialog' }));
      // Keyboard user: Tab to “Continue in browser” and press Enter; approval then replaces the
      // dialog's content while that button has focus.
      const next = scope.getByRole('button', { name: 'Continue in browser' });
      while (document.activeElement !== next) await userEvent.tab();
      await userEvent.keyboard('{Enter}');
      await new Promise((resolve) => setTimeout(resolve, 300));
      await userEvent.keyboard('{Escape}');
      await new Promise((resolve) => setTimeout(resolve, 400));
    }
  },
  render: () => (
    <Compare
      pr={1466}
      title="Sign-in lost keyboard focus, Escape and the Tab trap when its view changed"
      wrong={
        <p>
          The dialog listened for Escape/Tab on itself. Sign-in replaces its content as approval
          arrives, removing the focused button, so focus fell to the page behind the dialog: Escape
          stopped working and Tab wandered into the page.
        </p>
      }
      fixed={
        <p>
          Keys are handled at the document while a dialog is open, focus returns to the dialog when
          its focused control disappears, and Tab can reach “Details”. The play step opens each
          dialog, clicks <b>Continue in browser</b> (approval swaps the view), then presses
          Escape. Try it yourself with the keyboard.
        </p>
      }
      before={<SignInDemo version="before" Modal={ModalBefore} />}
      after={<SignInDemo version="after" Modal={ModalAfter} />}
      height={360}
    />
  ),
};
